# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/helpers/similarity'

RSpec.describe Legion::Extensions::Apollo::Helpers::Similarity do
  describe '.cosine_similarity' do
    it 'returns 1.0 for identical vectors' do
      vec = [1.0, 0.0, 0.0]
      expect(described_class.cosine_similarity(vec_a: vec, vec_b: vec)).to be_within(0.001).of(1.0)
    end

    it 'returns 0.0 for orthogonal vectors' do
      vec_a = [1.0, 0.0]
      vec_b = [0.0, 1.0]
      expect(described_class.cosine_similarity(vec_a: vec_a, vec_b: vec_b)).to be_within(0.001).of(0.0)
    end

    it 'returns correct similarity for known vectors' do
      vec_a = [1.0, 2.0, 3.0]
      vec_b = [4.0, 5.0, 6.0]
      expect(described_class.cosine_similarity(vec_a: vec_a, vec_b: vec_b)).to be_within(0.001).of(0.9746)
    end

    it 'returns 0.0 for zero vectors' do
      vec_a = [0.0, 0.0]
      vec_b = [1.0, 1.0]
      expect(described_class.cosine_similarity(vec_a: vec_a, vec_b: vec_b)).to eq(0.0)
    end
  end

  describe '.above_corroboration_threshold?' do
    it 'returns true when similarity exceeds threshold' do
      expect(described_class.above_corroboration_threshold?(similarity: 0.95)).to be true
    end

    it 'returns false when similarity below threshold' do
      expect(described_class.above_corroboration_threshold?(similarity: 0.85)).to be false
    end
  end

  describe '.classify_match' do
    it 'returns :corroboration for high similarity same type' do
      result = described_class.classify_match(similarity: 0.95, same_content_type: true)
      expect(result).to eq(:corroboration)
    end

    it 'returns :contradiction for high similarity with contradicts relation' do
      result = described_class.classify_match(similarity: 0.95, same_content_type: true, contradicts: true)
      expect(result).to eq(:contradiction)
    end

    it 'returns :novel for low similarity' do
      result = described_class.classify_match(similarity: 0.5, same_content_type: true)
      expect(result).to eq(:novel)
    end
  end
end
