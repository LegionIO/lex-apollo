# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/runners/embedding'

RSpec.describe Legion::Extensions::Apollo::Runners::Embedding do
  let(:provenance) do
    { space_id: 'a' * 64, provider: 'test', model: 'embed', instance: 'local', model_revision: nil,
      identity_source: 'instance', dimensions: 2, task: 'document', prefixes: { document: '', query: '' }, normalization: 'none' }
  end
  let(:result) { { vector: [0.6, 0.8], provider: 'test', model: 'embed', instance: 'local', dimensions: 2, embedding_provenance: provenance } }

  before do
    stub_const('Legion::LLM::Call::Embeddings', Module.new)
    allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_return(result)
  end

  it 'preserves a valid stored document vector rather than charging for regeneration' do
    expect(Legion::LLM::Call::Embeddings).not_to receive(:generate)
    expect(described_class.document(text: 'stored', vector: '[1.0,2.0]', provenance: Legion::JSON.dump(provenance)))
      .to eq(vector: [1.0, 2.0], provenance: provenance)
  end

  it 'retains valid PostgreSQL JSONB provenance without regenerating its document vector' do
    stored = Sequel.pg_jsonb(provenance.transform_keys(&:to_s))
    expect(described_class.document(text: 'stored', vector: '[1.0,2.0]', provenance: stored))
      .to eq(vector: [1.0, 2.0], provenance: provenance)
  end

  it 'regenerates unprovenanced legacy embeddings instead of inventing provenance' do
    expect(described_class.document(text: 'legacy', vector: [9.0, 8.0])).to eq(vector: result[:vector], provenance: provenance)
  end

  it 'regenerates a query vector supplied as a document' do
    expect(described_class.document(text: 'document', vector: [9.0, 8.0], provenance: provenance.merge(task: 'query')))
      .to eq(vector: result[:vector], provenance: provenance)
  end

  it 'rejects an unavailable generator rather than supplying zeroes' do
    allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_return(vector: nil)
    expect { described_class.generate(text: 'missing') }.to raise_error(Legion::Extensions::Apollo::Helpers::Embedding::Error)
  end

  it 'rejects nonfinite, nonreal, zero and dimension-mismatched generated vectors' do
    [[Float::NAN, 1.0], [Float::INFINITY, 1.0], [Complex(1, 1), 1.0], [0.0, 0.0], [1.0]].each do |vector|
      allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_return(result.merge(vector: vector))
      expect { described_class.generate(text: 'invalid') }.to raise_error(Legion::Extensions::Apollo::Helpers::Embedding::Error)
    end
  end

  it 'rejects contradictory provider metadata and requested dimensions' do
    allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_return(result.merge(provider: 'another-provider'))
    expect { described_class.generate(text: 'invalid') }.to raise_error(Legion::Extensions::Apollo::Helpers::Embedding::Error)
    allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_return(result)
    expect { described_class.generate(text: 'invalid', dimensions: 3) }.to raise_error(Legion::Extensions::Apollo::Helpers::Embedding::Error)
  end

  it 'propagates native provider failures' do
    allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_raise(Legion::LLM::LLMError, 'provider unavailable')
    expect { described_class.generate(text: 'request') }.to raise_error(Legion::LLM::LLMError, 'provider unavailable')
  end

  it 'does not reinterpret programming failures as provider failures' do
    allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_raise(NoMethodError, 'broken provider integration')
    expect { described_class.generate(text: 'request') }.to raise_error(NoMethodError, 'broken provider integration')
  end
end
