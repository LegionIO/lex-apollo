# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/runners/entity_extractor'

RSpec.describe Legion::Extensions::Apollo::Runners::EntityExtractor do
  describe '.extract_entities' do
    it 'returns an explicit unavailable result when the LLM is not started' do
      allow(Legion::LLM).to receive(:started?).and_return(false)

      result = described_class.extract_entities(text: 'Jane works on lex-synapse')

      expect(result).to include(success: true, entities: [], source: :unavailable)
    end

    it 'returns filtered entities from the structured LLM boundary' do
      allow(Legion::LLM).to receive(:started?).and_return(true)
      allow(Legion::LLM).to receive(:structured).and_return(
        data: { entities: [
          { name: 'lex-synapse', type: 'repository', confidence: 0.9 },
          { name: 'Jane Doe', type: 'person', confidence: 0.8 },
          { name: 'low', type: 'person', confidence: 0.2 }
        ] }
      )

      result = described_class.extract_entities(
        text: 'Jane works on lex-synapse', entity_types: ['repository'], min_confidence: 0.85
      )

      expect(result).to include(success: true, source: :llm)
      expect(result[:entities]).to eq([{ name: 'lex-synapse', type: 'repository', confidence: 0.9 }])
    end

    it 'returns a typed failure when the LLM boundary fails' do
      allow(Legion::LLM).to receive(:started?).and_return(true)
      allow(Legion::LLM).to receive(:structured).and_raise(StandardError, 'provider timeout')

      result = described_class.extract_entities(text: 'anything')

      expect(result).to include(success: false, entities: [], source: :error)
      expect(result[:error]).to include('provider timeout')
    end

    it 'propagates programming errors instead of converting them into extraction failures' do
      allow(Legion::LLM).to receive(:started?).and_return(true)
      allow(Legion::LLM).to receive(:structured).and_raise(ArgumentError, 'bad schema')

      expect { described_class.extract_entities(text: 'anything') }.to raise_error(ArgumentError, 'bad schema')
    end

    it 'returns an empty result for blank text' do
      result = described_class.extract_entities(text: '')

      expect(result).to include(success: true, entities: [], source: :empty)
    end
  end
end
