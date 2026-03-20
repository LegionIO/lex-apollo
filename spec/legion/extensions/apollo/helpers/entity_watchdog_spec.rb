# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/helpers/entity_watchdog'

RSpec.describe Legion::Extensions::Apollo::Helpers::EntityWatchdog do
  describe '.detect_entities' do
    it 'detects person names (capitalized multi-word)' do
      entities = described_class.detect_entities(text: 'Talked to Jane Doe about the project')
      person = entities.find { |e| e[:type] == :person }
      expect(person).not_to be_nil
      expect(person[:value]).to eq('Jane Doe')
    end

    it 'detects service URLs' do
      entities = described_class.detect_entities(text: 'Deployed to https://api.example.com/v1')
      service = entities.find { |e| e[:type] == :service }
      expect(service).not_to be_nil
      expect(service[:value]).to include('example.com')
    end

    it 'detects repo references' do
      entities = described_class.detect_entities(text: 'Check LegionIO/lex-mesh for the code')
      repo = entities.find { |e| e[:type] == :repo }
      expect(repo).not_to be_nil
      expect(repo[:value]).to eq('LegionIO/lex-mesh')
    end

    it 'detects concept keywords from settings' do
      allow(described_class).to receive(:concept_pattern).and_return(/\b(?:kubernetes|terraform)\b/i)
      entities = described_class.detect_entities(text: 'Using Terraform to deploy Kubernetes')
      concepts = entities.select { |e| e[:type] == :concept }
      expect(concepts.size).to eq(2)
    end

    it 'deduplicates entities by type and lowercase value' do
      entities = described_class.detect_entities(text: 'Jane Doe met Jane Doe again')
      persons = entities.select { |e| e[:type] == :person }
      expect(persons.size).to eq(1)
    end

    it 'returns empty array for text with no entities' do
      entities = described_class.detect_entities(text: 'nothing special here')
      expect(entities).to be_empty
    end

    it 'filters by specified types' do
      entities = described_class.detect_entities(
        text:  'Jane Doe at https://example.com with LegionIO/lex-mesh',
        types: [:person]
      )
      expect(entities.all? { |e| e[:type] == :person }).to be true
    end
  end

  describe '.link_or_create' do
    it 'returns counts for empty entities' do
      result = described_class.link_or_create(entities: [])
      expect(result[:success]).to be true
      expect(result[:linked]).to eq(0)
      expect(result[:created]).to eq(0)
    end
  end
end
