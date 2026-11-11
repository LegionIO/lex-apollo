# frozen_string_literal: true

require 'sequel'
require 'spec_helper'
require 'legion/extensions/apollo/helpers/storage'

RSpec.describe Legion::Extensions::Apollo::Helpers::Storage do
  let(:db) { Sequel.sqlite }
  let(:provenance) do
    { space_id: 'a' * 64, dimensions: 2, provider: 'test', model: 'embedding', instance: 'local',
      model_revision: nil, identity_source: 'instance', task: 'document',
      prefixes: { document: '', query: '' }, normalization: 'none' }
  end

  let(:host) { Object.new.extend(described_class) }

  before do
    db.create_table(:apollo_entries) do
      primary_key :id
      String :tags
    end
  end

  after { db.disconnect }

  it 'filters any and all tags safely with quoted values' do
    quoted = "x'); DROP TABLE apollo_entries; --"
    both = db[:apollo_entries].insert(tags: Legion::JSON.dump(['ruby', quoted]))
    one = db[:apollo_entries].insert(tags: Legion::JSON.dump(['ruby']))
    db[:apollo_entries].insert(tags: Legion::JSON.dump(['else']))
    db[:apollo_entries].insert(tags: '[]')

    %i[any all].each do |mode|
      expected = mode == :all ? [both] : [both, one]
      dataset = host.send(:storage_filter_tags, dataset: db[:apollo_entries], tags: ['ruby', quoted], tag_match: mode)
      expect(dataset.order(:id).select_map(:id)).to eq(expected)
    end
  end

  it 'raises when tag filtering encounters malformed persisted JSON' do
    db[:apollo_entries].insert(tags: 'malformed')
    dataset = host.send(:storage_filter_tags, dataset: db[:apollo_entries], tags: ['ruby'])
    expect { dataset.all }.to raise_error(Sequel::DatabaseError)
  end

  it 'raises for malformed JSON and non-array tag values' do
    expect { host.send(:storage_deserialize_tags, tags: 'malformed') }.to raise_error(Legion::JSON::ParseError)
    expect { host.send(:storage_deserialize_tags, tags: '{"tag":"ruby"}') }.to raise_error(ArgumentError)
  end

  it 'round trips SQLite arrays and provenance without PostgreSQL types' do
    tags = ['comma,value', 'quote"value', 'unicode λ']
    expect(host.send(:storage_deserialize_tags, tags: host.send(:storage_serialize_tags, db: db, tags: tags))).to eq(tags)
    encoded = host.send(:storage_serialize_provenance, db: db, provenance: provenance)
    expect(Legion::JSON.load(encoded)).to eq(provenance)
    expect(host.send(:storage_serialize_embedding, db: db, vector: nil)).to be_nil
    expect(host.send(:storage_serialize_provenance, db: db, provenance: nil)).to be_nil
  end
end
