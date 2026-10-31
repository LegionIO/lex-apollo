# frozen_string_literal: true

require 'sequel'
require 'spec_helper'
require 'legion/extensions/apollo/helpers/graph_query'

RSpec.describe Legion::Extensions::Apollo::Helpers::GraphQuery do
  let(:db) { Sequel.sqlite }

  before do
    db.create_table(:apollo_entries) do
      primary_key :id
      String :content
      String :content_type
      Float :confidence
      String :tags
      String :source_agent
      String :status
      String :access_scope
      Integer :identity_principal_id
      Integer :identity_id
    end
    db.create_table(:apollo_relations) do
      Integer :from_entry_id
      Integer :to_entry_id
      String :relation_type
      Float :weight
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

  def entry(**attributes)
    db[:apollo_entries].insert({ content: 'node', content_type: 'fact', confidence: 0.9,
                                 status: 'confirmed', access_scope: 'global', tags: '[]' }.merge(attributes))
  end

  def relation(from:, to:, weight: 1.0, type: 'supports', **)
    db[:apollo_relations].insert(from_entry_id: from, to_entry_id: to, weight: weight, relation_type: type)
  end

  def traverse(entry_id:, depth: 3, relation_types: nil, requesting_principal_id: 11, **)
    sql = described_class.build_traversal_sql(relation_types: relation_types, requesting_principal_id: requesting_principal_id)
    db.fetch(sql, entry_id: entry_id, depth: depth, relation_types: relation_types,
                  requesting_principal_id: requesting_principal_id, spread_factor: 0.6, min_activation: 0.01).all
  end

  it 'keeps the maximum activation per native id across paths and bounded cycles' do
    seed = entry
    middle = entry
    target = entry
    relation(from: seed, to: target, weight: 0.1)
    relation(from: seed, to: middle)
    relation(from: middle, to: target)
    relation(from: target, to: seed)

    results = traverse(entry_id: seed)
    expect(results.map { |row| row[:id] }).to eq([seed, middle, target])
    expect(results.find { |row| row[:id] == seed }).to include(depth: 0, activation: 1.0)
    expect(results.find { |row| row[:id] == target }).to include(depth: 2)
    expect(results.find { |row| row[:id] == target }[:activation]).to be_within(0.00001).of(0.36)
  end

  it 'blocks private and archived nodes at every hop, including hidden bridges and the seed' do
    seed = entry
    private_bridge = entry(access_scope: 'private', identity_principal_id: 22)
    archived_bridge = entry(status: 'archived')
    hidden_private_child = entry
    hidden_archived_child = entry
    visible = entry(access_scope: 'private', identity_principal_id: 11)
    relation(from: seed, to: private_bridge)
    relation(from: seed, to: archived_bridge)
    relation(from: private_bridge, to: hidden_private_child)
    relation(from: archived_bridge, to: hidden_archived_child)
    relation(from: seed, to: visible)

    expect(traverse(entry_id: seed).map { |row| row[:id] }).to eq([seed, visible])
    expect(traverse(entry_id: private_bridge)).to eq([])
    expect(traverse(entry_id: archived_bridge)).to eq([])
    expect(traverse(entry_id: seed, requesting_principal_id: 0).map { |row| row[:id] }).to eq([seed])
  end

  it 'uses the shortest depth to break equal-activation ties and restricts edge types' do
    seed = entry
    middle = entry
    target = entry
    relation(from: seed, to: target, weight: 0.6)
    relation(from: seed, to: middle)
    relation(from: middle, to: target)
    excluded = entry
    relation(from: seed, to: excluded, type: "other'quoted")

    results = traverse(entry_id: seed, relation_types: ['supports'])
    expect(results.map { |row| row[:id] }).to eq([seed, middle, target])
    expect(results.find { |row| row[:id] == target }[:depth]).to eq(1)
    expect(traverse(entry_id: seed, depth: 0).map { |row| row[:id] }).to eq([seed])
    expect(traverse(entry_id: seed, relation_types: ["other'quoted"]).map { |row| row[:id] }).to eq([seed, excluded])
  end
end
