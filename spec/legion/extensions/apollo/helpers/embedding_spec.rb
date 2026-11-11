# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/helpers/embedding'

RSpec.describe Legion::Extensions::Apollo::Helpers::Embedding do
  let(:host) { Object.new.extend(Legion::Logging::Helper).extend(described_class) }

  let(:provenance) do
    { space_id: 'a' * 64, provider: 'test', model: 'embed', instance: 'local', model_revision: nil,
      identity_source: 'instance', dimensions: 2, task: 'document', prefixes: { document: '', query: '' }, normalization: 'none' }
  end

  it 'allows document/query pairing only inside a known equal space and dimension' do
    expect(host.send(:embedding_compatible?, left: provenance, right: provenance.merge(task: 'query'))).to be true
    expect(host.send(:embedding_compatible?, left: provenance, right: provenance.merge(space_id: 'b' * 64))).to be false
    expect(host.send(:embedding_compatible?, left: provenance, right: provenance.merge(dimensions: 3))).to be false
    expect(host.send(:embedding_compatible?, left: nil, right: nil)).to be false
  end

  it 'rejects stale space IDs with different model metadata and isolates unknown-revision instances' do
    expect(host.send(:embedding_compatible?, left: provenance, right: provenance.merge(model: 'different'))).to be false
    expect(host.send(:embedding_compatible?, left: provenance, right: provenance.merge(instance: 'different'))).to be false
    revision = provenance.merge(identity_source: 'revision', model_revision: 'immutable-revision')
    expect(host.send(:embedding_compatible?, left: revision, right: revision.merge(instance: 'another-instance', task: 'query'))).to be true
  end

  it 'rejects incomplete provenance even when its space identifier looks valid' do
    expect(host.send(:embedding_valid?, vector: [1.0, 2.0], provenance: provenance.except(:prefixes))).to be false
    expect(host.send(:embedding_valid?, vector: [1.0, 2.0], provenance: provenance.merge(identity_source: 'revision'))).to be false
    expect(host.send(:embedding_parse_provenance, value: '{bad json')).to be_nil
  end
end
