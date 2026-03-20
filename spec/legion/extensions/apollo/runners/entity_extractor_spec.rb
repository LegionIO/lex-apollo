# frozen_string_literal: true

require 'spec_helper'

require 'legion/extensions/apollo/helpers/confidence'
require 'legion/extensions/apollo/helpers/similarity'
require 'legion/extensions/apollo/helpers/graph_query'
require 'legion/extensions/apollo/runners/entity_extractor'

RSpec.describe Legion::Extensions::Apollo::Runners::EntityExtractor do
  let(:runner) do
    obj = Object.new
    obj.extend(described_class)
    obj
  end

  describe '#extract_entities' do
    context 'when Legion::LLM is not available' do
      before { hide_const('Legion::LLM') if defined?(Legion::LLM) }

      it 'returns an empty entity list' do
        result = runner.extract_entities(text: 'Jane works on lex-synapse')
        expect(result[:success]).to be true
        expect(result[:entities]).to eq([])
        expect(result[:source]).to eq(:unavailable)
      end
    end

    context 'when Legion::LLM is available' do
      let(:llm_result) do
        {
          data: {
            entities: [
              { name: 'lex-synapse', type: 'repository', confidence: 0.9 },
              { name: 'Jane Doe',    type: 'person',     confidence: 0.8 }
            ]
          }
        }
      end

      before do
        stub_const('Legion::LLM', Module.new do
          def self.started? = true

          def self.structured(**_opts) = { data: { entities: [] } }
        end)
        allow(Legion::LLM).to receive(:structured).and_return(llm_result)
      end

      it 'returns extracted entities' do
        result = runner.extract_entities(text: 'Jane works on lex-synapse')
        expect(result[:success]).to be true
        expect(result[:entities].size).to eq(2)
        expect(result[:source]).to eq(:llm)
      end

      it 'filters to configured entity types' do
        result = runner.extract_entities(
          text:         'Jane works on lex-synapse',
          entity_types: ['repository']
        )
        expect(result[:entities].all? { |e| e[:type] == 'repository' }).to be true
      end

      it 'applies minimum confidence filter' do
        result = runner.extract_entities(
          text:           'Jane works on lex-synapse',
          min_confidence: 0.85
        )
        expect(result[:entities].size).to eq(1)
        expect(result[:entities].first[:name]).to eq('lex-synapse')
      end
    end

    context 'when LLM raises' do
      before do
        stub_const('Legion::LLM', Module.new do
          def self.started? = true

          def self.structured(**_opts) = raise(StandardError, 'timeout')
        end)
      end

      it 'returns success false with error message' do
        result = runner.extract_entities(text: 'anything')
        expect(result[:success]).to be false
        expect(result[:error]).to include('timeout')
      end
    end

    context 'with empty text' do
      it 'returns early with empty list' do
        result = runner.extract_entities(text: '')
        expect(result[:success]).to be true
        expect(result[:entities]).to eq([])
      end

      it 'handles nil text' do
        result = runner.extract_entities(text: nil)
        expect(result[:success]).to be true
        expect(result[:entities]).to eq([])
      end
    end
  end

  describe '#entity_extraction_prompt' do
    it 'returns a non-empty string' do
      prompt = runner.entity_extraction_prompt(
        text: 'test text', entity_types: %w[person service]
      )
      expect(prompt).to be_a(String)
      expect(prompt).to include('person')
      expect(prompt).to include('service')
    end
  end

  describe '#entity_schema' do
    it 'returns a JSON Schema hash' do
      schema = runner.entity_schema
      expect(schema[:type]).to eq('object')
      expect(schema[:properties]).to have_key(:entities)
    end
  end
end
