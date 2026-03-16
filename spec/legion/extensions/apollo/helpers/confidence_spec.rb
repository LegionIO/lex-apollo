# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/helpers/confidence'

RSpec.describe Legion::Extensions::Apollo::Helpers::Confidence do
  describe 'constants' do
    it 'defines INITIAL_CONFIDENCE' do
      expect(described_class::INITIAL_CONFIDENCE).to eq(0.5)
    end

    it 'defines CORROBORATION_BOOST' do
      expect(described_class::CORROBORATION_BOOST).to eq(0.3)
    end

    it 'defines RETRIEVAL_BOOST' do
      expect(described_class::RETRIEVAL_BOOST).to eq(0.02)
    end

    it 'defines HOURLY_DECAY_FACTOR' do
      expect(described_class::HOURLY_DECAY_FACTOR).to eq(0.998)
    end

    it 'defines DECAY_THRESHOLD' do
      expect(described_class::DECAY_THRESHOLD).to eq(0.1)
    end

    it 'defines CORROBORATION_SIMILARITY_THRESHOLD' do
      expect(described_class::CORROBORATION_SIMILARITY_THRESHOLD).to eq(0.9)
    end

    it 'defines WRITE_CONFIDENCE_GATE' do
      expect(described_class::WRITE_CONFIDENCE_GATE).to eq(0.6)
    end

    it 'defines WRITE_NOVELTY_GATE' do
      expect(described_class::WRITE_NOVELTY_GATE).to eq(0.3)
    end

    it 'defines STALE_DAYS' do
      expect(described_class::STALE_DAYS).to eq(90)
    end
  end

  describe '.apply_decay' do
    it 'multiplies confidence by HOURLY_DECAY_FACTOR' do
      result = described_class.apply_decay(confidence: 1.0)
      expect(result).to eq(0.998)
    end

    it 'accepts a custom factor' do
      result = described_class.apply_decay(confidence: 1.0, factor: 0.5)
      expect(result).to eq(0.5)
    end

    it 'clamps to 0.0 minimum' do
      result = described_class.apply_decay(confidence: 0.001, factor: 0.001)
      expect(result).to be >= 0.0
    end
  end

  describe '.apply_retrieval_boost' do
    it 'adds RETRIEVAL_BOOST to confidence' do
      result = described_class.apply_retrieval_boost(confidence: 0.5)
      expect(result).to eq(0.52)
    end

    it 'clamps to 1.0 maximum' do
      result = described_class.apply_retrieval_boost(confidence: 0.99)
      expect(result).to eq(1.0)
    end
  end

  describe '.apply_corroboration_boost' do
    it 'adds CORROBORATION_BOOST to confidence' do
      result = described_class.apply_corroboration_boost(confidence: 0.5)
      expect(result).to eq(0.8)
    end

    it 'clamps to 1.0 maximum' do
      result = described_class.apply_corroboration_boost(confidence: 0.9)
      expect(result).to eq(1.0)
    end
  end

  describe '.decayed?' do
    it 'returns true when confidence below threshold' do
      expect(described_class.decayed?(confidence: 0.05)).to be true
    end

    it 'returns false when confidence at or above threshold' do
      expect(described_class.decayed?(confidence: 0.1)).to be false
    end
  end

  describe '.meets_write_gate?' do
    it 'returns true when both gates met' do
      expect(described_class.meets_write_gate?(confidence: 0.7, novelty: 0.4)).to be true
    end

    it 'returns false when confidence below gate' do
      expect(described_class.meets_write_gate?(confidence: 0.5, novelty: 0.4)).to be false
    end

    it 'returns false when novelty below gate' do
      expect(described_class.meets_write_gate?(confidence: 0.7, novelty: 0.2)).to be false
    end
  end
end
