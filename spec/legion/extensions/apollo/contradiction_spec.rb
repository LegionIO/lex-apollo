# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Apollo Contradiction Detection' do
  let(:knowledge) { Object.new.extend(Legion::Extensions::Apollo::Runners::Knowledge) }

  describe '#llm_detects_conflict?' do
    it 'returns false when LLM unavailable' do
      expect(knowledge.send(:llm_detects_conflict?, 'sky is blue', 'sky is red')).to be false
    end
  end

  describe '#detect_contradictions' do
    it 'returns empty when ApolloEntry model unavailable' do
      expect(knowledge.send(:detect_contradictions, 1, nil, 'test')).to eq([])
    end
  end
end
