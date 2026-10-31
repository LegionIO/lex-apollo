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

  before do
    db.create_table(:apollo_entries) do
      primary_key :id
      String :content
      String :content_type
      Float :confidence
      String :tags
      String :source_agent
      Integer :access_count, default: 0
      DateTime :created_at
      String :knowledge_domain
      String :status
      String :access_scope
      Integer :identity_principal_id
      Integer :identity_id
      String :embedding
      String :embedding_space_id
      Integer :embedding_dimensions
      String :embedding_provenance
    end
    db.create_table(:identities) do
      primary_key :id
      Integer :principal_id
    end
    db.create_table(:identity_group_memberships) do
      Integer :principal_id
      Integer :group_id
    end
  end

  after { db.disconnect }

  def insert_entry(vector: [1.0, 0.0], vector_provenance: provenance, tags: [], **attributes)
    db[:apollo_entries].insert({ content: 'entry', content_type: 'fact', confidence: 0.9,
                                 status: 'confirmed', access_scope: 'global',
                                 embedding: described_class.serialize_embedding(db: db, vector: vector),
                                 embedding_space_id: vector_provenance&.dig(:space_id),
                                 embedding_dimensions: vector_provenance&.dig(:dimensions),
                                 embedding_provenance: described_class.serialize_provenance(db: db, provenance: vector_provenance),
                                 tags: described_class.serialize_tags(db: db, tags: tags) }.merge(attributes))
  end

  def search(**filters)
    described_class.semantic_search(db: db, embedding: [1.0, 0.0], provenance: provenance.merge(task: 'query'), **filters)
  end

  it 'ranks every eligible row before taking top-k and preserves native ids and decoded tags' do
    12.times { insert_entry(vector: [0.0, 1.0]) }
    winner = insert_entry(tags: ['best'])
    tied = insert_entry(tags: ['tie'])

    results = search(limit: 2)
    expect(results.map { |row| row[:id] }).to eq([winner, tied])
    expect(results.map { |row| row[:distance] }).to eq([0.0, 0.0])
    expect(results.first[:tags]).to eq(['best'])
  end

  it 'applies status, confidence, domain, source and visibility filters before top-k' do
    insert_entry(confidence: 0.1, knowledge_domain: 'facts')
    insert_entry(status: 'archived', knowledge_domain: 'facts')
    insert_entry(knowledge_domain: 'other')
    insert_entry(knowledge_domain: 'facts', source_agent: 'excluded')
    insert_entry(knowledge_domain: 'facts', access_scope: 'private', identity_principal_id: 22)
    winner = insert_entry(vector: [0.8, 0.6], knowledge_domain: 'facts')

    results = search(limit: 1, min_confidence: 0.5, domain: 'facts', exclude_source_agents: ['excluded'], requesting_principal_id: 11)
    expect(results.map { |row| row[:id] }).to eq([winner])
    expect(results.first[:distance]).to be_within(0.00001).of(0.2)
  end

  it 'ranks contradiction candidates within the exact scope and owner before limiting' do
    insert_entry(access_scope: 'global')
    insert_entry(access_scope: 'private', identity_principal_id: 22)
    insert_entry(access_scope: 'team', identity_principal_id: 11)
    own = insert_entry(vector: [0.8, 0.6], access_scope: 'private', identity_principal_id: 11)

    results = described_class.semantic_search(db: db, embedding: [1.0, 0.0], provenance: provenance,
                                              limit: 1, access_scope: 'private', identity_principal_id: 11)
    expect(results).to contain_exactly(include(id: own, access_scope: 'private', identity_principal_id: 11))
  end
  it 'honors private ownership, identity ownership and team membership without exposing other owners' do
    global = insert_entry
    private_entry = insert_entry(access_scope: 'private', identity_principal_id: 11)
    identity = db[:identities].insert(principal_id: 11)
    identity_entry = insert_entry(access_scope: 'private', identity_id: identity)
    team = insert_entry(access_scope: 'team', identity_principal_id: 22)
    db[:identity_group_memberships].multi_insert([{ principal_id: 11, group_id: 1 }, { principal_id: 22, group_id: 1 }])
    insert_entry(access_scope: 'private', identity_principal_id: 22)
    insert_entry(access_scope: 'team', identity_principal_id: 33)
    insert_entry(access_scope: 'private')

    expect(search(requesting_principal_id: 11).map { |row| row[:id] }).to eq([global, private_entry, identity_entry, team])
    expect(search(requesting_principal_id: 0).map { |row| row[:id] }).to eq([global])
  end

  it 'implements any and all tags identically in search and dataset filtering with quoted values' do
    quoted = "x'); DROP TABLE apollo_entries; --"
    both = insert_entry(tags: ['ruby', quoted])
    one = insert_entry(tags: ['ruby'])
    insert_entry(tags: ['else'])
    insert_entry(tags: [])
    db[:apollo_entries].insert(tags: '{}')
    db[:apollo_entries].insert(tags: 'malformed')

    %i[any all].each do |mode|
      expected = mode == :all ? [both] : [both, one]
      expect(search(tags: ['ruby', quoted], tag_match: mode).map { |row| row[:id] }).to eq(expected)
      dataset = described_class.filter_tags(dataset: db[:apollo_entries], tags: ['ruby', quoted], tag_match: mode)
      expect(dataset.order(:id).select_map(:id)).to eq(expected)
    end
  end

  it 'excludes legacy, different-space, inconsistent and malformed vectors without comparison' do
    insert_entry(vector_provenance: nil)
    insert_entry(vector_provenance: provenance.merge(space_id: 'b' * 64))
    insert_entry(vector: [1.0], vector_provenance: provenance.merge(dimensions: 1))
    insert_entry(vector: [1.0])
    insert_entry(vector: [0.0, 0.0])
    insert_entry(embedding: 'broken')
    insert_entry(vector_provenance: provenance.merge(space_id: 'b' * 64), embedding_space_id: provenance[:space_id])
    valid = insert_entry(vector: [0.8, 0.6])

    expect(search(limit: 1).map { |row| row[:id] }).to eq([valid])
  end

  it 'rejects a query without valid provenance rather than searching a guessed vector space' do
    expect { described_class.semantic_search(db: db, embedding: [1.0, 0.0], provenance: nil) }.to raise_error(ArgumentError)
    expect { search(limit: 0) }.to raise_error(ArgumentError)
  end

  it 'round trips SQLite arrays and provenance without PostgreSQL types' do
    tags = ['comma,value', 'quote"value', 'unicode λ']
    expect(described_class.deserialize_tags(tags: described_class.serialize_tags(db: db, tags: tags))).to eq(tags)
    encoded = described_class.serialize_provenance(db: db, provenance: provenance)
    expect(Legion::JSON.load(encoded)).to eq(provenance)
    expect(described_class.serialize_embedding(db: db, vector: nil)).to be_nil
    expect(described_class.serialize_provenance(db: db, provenance: nil)).to be_nil
    expect(described_class.deserialize_tags(tags: '{}')).to eq([])
  end
end
