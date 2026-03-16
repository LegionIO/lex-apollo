# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/helpers/confidence'
require 'legion/extensions/apollo/runners/knowledge'

RSpec.describe Legion::Extensions::Apollo::Runners::Knowledge do
  let(:runner) do
    obj = Object.new
    obj.extend(described_class)
    obj
  end

  describe '#store_knowledge' do
    it 'returns a message payload hash' do
      result = runner.store_knowledge(
        content:      'Vault namespace ash1234 uses PKI',
        content_type: :fact,
        tags:         %w[vault pki]
      )
      expect(result).to be_a(Hash)
      expect(result[:action]).to eq(:store)
      expect(result[:content]).to eq('Vault namespace ash1234 uses PKI')
      expect(result[:content_type]).to eq(:fact)
      expect(result[:tags]).to eq(%w[vault pki])
    end

    it 'includes source_agent when provided' do
      result = runner.store_knowledge(
        content: 'test', content_type: :fact, source_agent: 'worker-1'
      )
      expect(result[:source_agent]).to eq('worker-1')
    end

    it 'rejects invalid content_type' do
      expect do
        runner.store_knowledge(content: 'test', content_type: :invalid)
      end.to raise_error(ArgumentError, /content_type/)
    end
  end

  describe '#query_knowledge' do
    it 'returns a query payload hash' do
      result = runner.query_knowledge(query: 'PKI configuration')
      expect(result[:action]).to eq(:query)
      expect(result[:query]).to eq('PKI configuration')
      expect(result[:limit]).to eq(10)
      expect(result[:min_confidence]).to eq(0.3)
    end

    it 'accepts custom limit and filters' do
      result = runner.query_knowledge(
        query: 'vault', limit: 5, min_confidence: 0.5,
        status: [:confirmed], tags: %w[vault]
      )
      expect(result[:limit]).to eq(5)
      expect(result[:min_confidence]).to eq(0.5)
      expect(result[:status]).to eq([:confirmed])
      expect(result[:tags]).to eq(%w[vault])
    end
  end

  describe '#related_entries' do
    it 'returns a traversal payload hash' do
      result = runner.related_entries(entry_id: 'uuid-123')
      expect(result[:action]).to eq(:traverse)
      expect(result[:entry_id]).to eq('uuid-123')
      expect(result[:depth]).to eq(2)
    end

    it 'accepts relation_types filter' do
      result = runner.related_entries(
        entry_id: 'uuid-123', relation_types: %w[causes depends_on], depth: 3
      )
      expect(result[:relation_types]).to eq(%w[causes depends_on])
      expect(result[:depth]).to eq(3)
    end
  end

  describe '#deprecate_entry' do
    it 'returns a deprecate payload' do
      result = runner.deprecate_entry(entry_id: 'uuid-123', reason: 'outdated')
      expect(result[:action]).to eq(:deprecate)
      expect(result[:entry_id]).to eq('uuid-123')
      expect(result[:reason]).to eq('outdated')
    end
  end
end
