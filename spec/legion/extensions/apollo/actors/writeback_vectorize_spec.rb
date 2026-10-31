# frozen_string_literal: true

require 'spec_helper'

$LOADED_FEATURES << 'legion/extensions/actors/subscription' unless $LOADED_FEATURES.include?('legion/extensions/actors/subscription')
require 'legion/extensions/apollo/actors/writeback_vectorize'

RSpec.describe Legion::Extensions::Apollo::Actor::WritebackVectorize do
  subject(:actor) { described_class.new }

  let(:provenance) do
    { space_id: 'a' * 64, provider: 'embed-provider', model: 'embed-model', instance: 'local', model_revision: nil,
      identity_source: 'instance', dimensions: 2, task: 'document', prefixes: { document: '', query: '' }, normalization: 'none' }
  end
  let(:payload) do
    { content: 'test content', content_type: 'observation', tags: ['test'], source_provider: 'producer',
      context: { request_id: 'request' }, source_model: 'producer-model' }
  end
  let(:accepted_payloads) { [] }
  let(:ingest_result) { { success: true } }

  before do
    stub_const('Legion::LLM::Call::Embeddings', Module.new)
    allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_return(
      vector: [0.6, 0.8], provider: 'embed-provider', model: 'embed-model', instance: 'local', dimensions: 2, embedding_provenance: provenance
    )
    allow(Legion::Extensions::Apollo::Helpers::Capability).to receive(:can_write?).and_return(true)
    received = accepted_payloads
    result = ingest_result
    knowledge = Module.new do
      define_method(:handle_ingest) do |**input|
        received << input
        result
      end
    end
    stub_const('Legion::Extensions::Apollo::Runners::Knowledge', knowledge)
  end

  it 'dispatches keywords to a callable receiver and preserves producer ownership and source metadata' do
    result = actor.runner_class.public_send(actor.runner_function, **payload)

    expect(result[:success]).to be true
    expect(accepted_payloads).to eq([payload.merge(identity_principal_id: nil, identity_id: nil, identity_canonical_name: nil,
                                                   embedding: [0.6, 0.8], embedding_provenance: provenance)])
  end

  it 'preserves an explicit producer owner' do
    actor.runner_class.public_send(actor.runner_function, **payload, identity_principal_id: 17)
    expect(accepted_payloads.first[:identity_principal_id]).to eq(17)
  end

  it 'raises a generation failure to the subscription retry boundary' do
    allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_return(vector: nil)
    expect { actor.runner_class.public_send(actor.runner_function, **payload) }
      .to raise_error(Legion::Extensions::Apollo::Helpers::Embedding::Error)
    expect(accepted_payloads).to be_empty
  end

  context 'when ingestion rejects the payload' do
    let(:ingest_result) { { success: false, error: :invalid_access_scope } }

    it 'raises instead of acknowledging the subscription delivery' do
      expect { actor.runner_class.public_send(actor.runner_function, **payload) }.to raise_error(IOError)
    end
  end

  it 'publishes vectorized broker input to storage instead of inheriting its inbound route' do
    allow(Legion::Extensions::Apollo::Helpers::Capability).to receive(:can_write?).and_return(false)
    channel = double('channel', using_publisher_confirmations?: true, confirm_select: true, wait_for_confirms: true)
    exchange = double('exchange', name: 'legion.apollo', channel: channel, on_return: nil)
    allow(Legion::Extensions::Apollo::Transport::Exchanges::Apollo).to receive(:cached_instance).and_return(exchange)
    published = nil
    allow(exchange).to receive(:publish) { |body, **envelope| published = [Legion::JSON.load(body), envelope] }

    result = actor.runner_class.public_send(actor.runner_function, **payload,
                                            routing_key: 'legion.apollo.writeback.vectorize', exchange: 'incoming',
                                            correlation_id: 'source-request', encrypt: false)

    expect(result[:success]).to be true
    expect(published.first).to include(content: payload[:content], embedding: [0.6, 0.8], embedding_provenance: provenance)
    expect(published.last).to include(routing_key: 'legion.apollo.writeback.store', correlation_id: 'source-request')
  end

  it 'does not turn an unchecked or failed publication into success' do
    allow(Legion::Extensions::Apollo::Helpers::Capability).to receive(:can_write?).and_return(false)
    message = instance_double(Legion::Extensions::Apollo::Transport::Messages::Writeback)
    allow(Legion::Extensions::Apollo::Transport::Messages::Writeback).to receive(:new).and_return(message)
    [nil, { accepted: false, status: :unroutable }].each do |result|
      allow(message).to receive(:publish).and_return(result)
      expect { actor.runner_class.public_send(actor.runner_function, **payload) }.to raise_error(IOError)
    end
  end
end
