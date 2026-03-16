# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/helpers/graph_query'

RSpec.describe Legion::Extensions::Apollo::Helpers::GraphQuery do
  describe 'constants' do
    it 'defines SPREAD_FACTOR' do
      expect(described_class::SPREAD_FACTOR).to eq(0.6)
    end

    it 'defines DEFAULT_DEPTH' do
      expect(described_class::DEFAULT_DEPTH).to eq(2)
    end

    it 'defines MIN_ACTIVATION' do
      expect(described_class::MIN_ACTIVATION).to eq(0.1)
    end
  end

  describe '.build_traversal_sql' do
    it 'returns SQL string with entry_id placeholder' do
      sql = described_class.build_traversal_sql(depth: 2)
      expect(sql).to include('apollo_entries')
      expect(sql).to include('apollo_relations')
      expect(sql).to include('WITH RECURSIVE')
      expect(sql).to include('$entry_id')
    end

    it 'includes relation type filter when specified' do
      sql = described_class.build_traversal_sql(depth: 2, relation_types: %w[causes depends_on])
      expect(sql).to include("'causes'")
      expect(sql).to include("'depends_on'")
    end

    it 'respects custom depth' do
      sql = described_class.build_traversal_sql(depth: 3)
      expect(sql).to include('g.depth < 3')
    end

    it 'applies spread factor and min activation' do
      sql = described_class.build_traversal_sql(depth: 2)
      expect(sql).to include('0.6')
      expect(sql).to include('0.1')
    end
  end

  describe '.build_semantic_search_sql' do
    it 'returns SQL with vector placeholder' do
      sql = described_class.build_semantic_search_sql(limit: 5, min_confidence: 0.3)
      expect(sql).to include('apollo_entries')
      expect(sql).to include('$embedding')
      expect(sql).to include('<=>')
      expect(sql).to include('LIMIT 5')
    end

    it 'includes status filter' do
      sql = described_class.build_semantic_search_sql(limit: 10, statuses: %w[confirmed])
      expect(sql).to include("'confirmed'")
    end

    it 'includes tag filter when specified' do
      sql = described_class.build_semantic_search_sql(limit: 10, tags: %w[vault dns])
      expect(sql).to include("'vault'")
      expect(sql).to include("'dns'")
      expect(sql).to include('&&')
    end
  end
end
