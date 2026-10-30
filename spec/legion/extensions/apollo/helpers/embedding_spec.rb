# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/helpers/embedding'

RSpec.describe Legion::Extensions::Apollo::Helpers::Embedding do
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
    expect { described_class.generate(text: 'missing') }.to raise_error(described_class::Error)
  end

  it 'rejects nonfinite, nonreal, zero and dimension-mismatched generated vectors' do
    [[Float::NAN, 1.0], [Float::INFINITY, 1.0], [Complex(1, 1), 1.0], [0.0, 0.0], [1.0]].each do |vector|
      allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_return(result.merge(vector: vector))
      expect { described_class.generate(text: 'invalid') }.to raise_error(described_class::Error)
    end
  end

  it 'rejects contradictory provider metadata and requested dimensions' do
    allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_return(result.merge(provider: 'another-provider'))
    expect { described_class.generate(text: 'invalid') }.to raise_error(described_class::Error)
    allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_return(result)
    expect { described_class.generate(text: 'invalid', dimensions: 3) }.to raise_error(described_class::Error)
  end

  it 'allows document/query pairing only inside a known equal space and dimension' do
    expect(described_class.compatible?(left: provenance, right: provenance.merge(task: 'query'))).to be true
    expect(described_class.compatible?(left: provenance, right: provenance.merge(space_id: 'b' * 64))).to be false
    expect(described_class.compatible?(left: provenance, right: provenance.merge(dimensions: 3))).to be false
    expect(described_class.compatible?(left: nil, right: nil)).to be false
  end

  it 'rejects stale space IDs with different model metadata and isolates unknown-revision instances' do
    expect(described_class.compatible?(left: provenance, right: provenance.merge(model: 'different'))).to be false
    expect(described_class.compatible?(left: provenance, right: provenance.merge(instance: 'different'))).to be false
    revision = provenance.merge(identity_source: 'revision', model_revision: 'immutable-revision')
    expect(described_class.compatible?(left: revision, right: revision.merge(instance: 'another-instance', task: 'query'))).to be true
  end

  it 'rejects incomplete provenance even when its space identifier looks valid' do
    expect(described_class.valid?(vector: [1.0, 2.0], provenance: provenance.except(:prefixes))).to be false
    expect(described_class.valid?(vector: [1.0, 2.0], provenance: provenance.merge(identity_source: 'revision'))).to be false
    expect(described_class.parse_provenance(value: '{bad json')).to be_nil
  end
end
