# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/helpers/tag_normalizer'
require 'legion/extensions/apollo/helpers/writeback'

RSpec.describe Legion::Extensions::Apollo::Helpers::Writeback do
  let(:base_request) do
    double('Request',
           messages: [{ role: 'user', content: 'How does RabbitMQ clustering work?' }],
           caller:   { requested_by: { identity: 'user@example.com', type: :human } })
  end

  let(:base_response) do
    double('Response',
           message:    { content: 'RabbitMQ clustering works by...' * 20 },
           model:      'claude-sonnet-4-6',
           tool_calls: [])
  end

  describe '.should_capture?' do
    it 'returns false for short responses' do
      short = double('Response', message: { content: 'yes' }, tool_calls: [])
      expect(described_class.should_capture?(response: short, enrichments: {})).to be false
    end

    it 'returns false when no research tools were used' do
      expect(described_class.should_capture?(response: base_response, enrichments: {})).to be false
    end

    it 'returns true when research tools were used' do
      enrichments = {}
      long_response = double('Response',
                             message:    { content: 'x' * 100 },
                             model:      'claude-sonnet-4-6',
                             tool_calls: [{ name: 'read_file' }])
      expect(described_class.should_capture?(response: long_response, enrichments: enrichments)).to be true
    end

    it 'returns false for echo chamber (apollo had results, no additional research)' do
      enrichments = {
        'rag_context:apollo_results' => { count: 3 },
        'tool_calls'                 => []
      }
      long_response = double('Response', message: { content: 'x' * 100 }, tool_calls: [])
      expect(described_class.should_capture?(response: long_response, enrichments: enrichments)).to be false
    end

    it 'recognizes canonical research tools represented by typed objects or either hash key style' do
      response_type = Data.define(:message, :tools)
      tool_type = Data.define(:name)
      tools = [{ name: 'read_file' }, { 'name' => 'search_files' },
               tool_type.new(name: 'search_content'), tool_type.new(name: 'run_command')]
      decisions = tools.map do |tool|
        response = response_type.new(message: { content: 'Independent research findings. ' * 4 }, tools: [tool])
        described_class.should_capture?(response: response, enrichments: {})
      end

      expect(decisions).to all(be true)
    end

    it 'does not mistake a non-research canonical tool for new evidence' do
      response = Data.define(:message, :tools).new(
        message: { content: 'An answer based only on existing Apollo knowledge. ' * 4 },
        tools:   [Data.define(:name).new(name: 'apollo_query')]
      )

      expect(described_class.should_capture?(response:    response,
                                             enrichments: { 'rag_context:apollo_results' => { count: 3 } })).to be false
    end

    it 'retains research evidence supplied through enrichments when the final response has no tools' do
      response = Data.define(:message, :tools).new(message: { content: 'Completed research findings. ' * 4 }, tools: [])

      expect(described_class.should_capture?(response:    response,
                                             enrichments: { 'tool_calls' => [{ 'name' => 'read_file' }] })).to be true
    end
  end

  describe '.build_payload' do
    it 'builds payload with identity context' do
      payload = described_class.build_payload(
        request:        base_request,
        response:       base_response,
        source_channel: 'chat'
      )
      expect(payload[:submitted_by]).to eq('user@example.com')
      expect(payload[:source_agent]).to eq('claude-sonnet-4-6')
      expect(payload[:content_type]).to eq('observation')
      expect(payload[:source_channel]).to eq('chat_synthesis')
    end

    it 'truncates content to max length' do
      long_response = double('Response',
                             message: { content: 'x' * 10_000 },
                             model:   'test')
      payload = described_class.build_payload(request: base_request, response: long_response)
      expect(payload[:content].length).to be <= 4000
    end

    it 'includes content_hash' do
      payload = described_class.build_payload(request: base_request, response: base_response)
      expect(payload[:content_hash]).to be_a(String)
      expect(payload[:content_hash].length).to eq(32)
    end

    it 'normalizes tags' do
      payload = described_class.build_payload(request: base_request, response: base_response)
      expect(payload[:tags]).to all(match(/\A[a-z0-9-]+\z/))
    end
  end

  describe '.evaluate_and_route' do
    let(:response) { double('Response', message: { content: 'research findings ' * 10 }, model: 'producer-model', tool_calls: [{ name: 'read_file' }]) }
    let(:provenance) do
      { space_id: 'a' * 64, provider: 'embed-provider', model: 'embed-model', instance: 'local', model_revision: nil,
        identity_source: 'instance', dimensions: 2, task: 'document', prefixes: { document: '', query: '' }, normalization: 'none' }
    end

    before do
      stub_const('Legion::LLM::Call::Embeddings', Module.new)
      allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_return(
        vector: [0.6, 0.8], provider: 'embed-provider', model: 'embed-model', instance: 'local', dimensions: 2, embedding_provenance: provenance
      )
      allow(Legion::Extensions::Apollo::Helpers::Capability).to receive(:can_embed?).and_return(true)
      allow(Legion::Extensions::Apollo::Helpers::Capability).to receive(:can_write?).and_return(true)
    end

    it 'passes real generated vectors and original context to ingestion' do
      received = []
      knowledge = Module.new do
        define_method(:handle_ingest) do |**input|
          received << input
          { success: true }
        end
      end
      stub_const('Legion::Extensions::Apollo::Runners::Knowledge', knowledge)
      allow(base_request).to receive(:metadata).and_return(context: { request_id: 'research' }, identity_principal_id: 21, access_scope: 'private')

      expect(described_class.evaluate_and_route(request: base_request, response: response)[:success]).to be true
      expect(received.first).to include(embedding: [0.6, 0.8], embedding_provenance: provenance, source_model: 'producer-model',
                                        context: { request_id: 'research' }, identity_principal_id: 21, access_scope: 'private')
    end

    it 'propagates rejected ingestion instead of silently switching to an unchecked broker path' do
      knowledge = Module.new do
        def handle_ingest(**)
          { success: false, error: :rejected }
        end
      end
      stub_const('Legion::Extensions::Apollo::Runners::Knowledge', knowledge)
      expect { described_class.evaluate_and_route(request: base_request, response: response) }.to raise_error(IOError)
    end

    it 'propagates embedding errors rather than capturing fabricated vectors' do
      allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_return(vector: nil)
      expect { described_class.evaluate_and_route(request: base_request, response: response) }
        .to raise_error(Legion::Extensions::Apollo::Helpers::Embedding::Error)
    end

    it 'requires accepted publication when this node cannot generate embeddings' do
      allow(Legion::Extensions::Apollo::Helpers::Capability).to receive(:can_embed?).and_return(false)
      message = instance_double(Legion::Extensions::Apollo::Transport::Messages::Writeback, publish: { accepted: false })
      allow(Legion::Extensions::Apollo::Transport::Messages::Writeback).to receive(:new).and_return(message)
      expect { described_class.evaluate_and_route(request: base_request, response: response) }.to raise_error(IOError)
    end
  end

  describe '.content_hash' do
    it 'normalizes whitespace before hashing' do
      hash1 = described_class.content_hash(content: 'hello  world')
      hash2 = described_class.content_hash(content: 'hello world')
      expect(hash1).to eq(hash2)
    end
  end
end
