# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/helpers/similarity'

RSpec.describe Legion::Extensions::Apollo::Helpers::Similarity do
  let(:host) { Object.new.extend(described_class) }

  before do
    allow(host).to receive(:settings).and_return(Legion::Extensions::Apollo.default_settings)
  end

  describe 'cosine similarity' do
    it 'returns 1.0 for identical vectors' do
      vec = [1.0, 0.0, 0.0]
      expect(host.send(:similarity_cosine, vec_a: vec, vec_b: vec)).to be_within(0.001).of(1.0)
    end

    it 'returns 0.0 for orthogonal vectors' do
      vec_a = [1.0, 0.0]
      vec_b = [0.0, 1.0]
      expect(host.send(:similarity_cosine, vec_a: vec_a, vec_b: vec_b)).to be_within(0.001).of(0.0)
    end

    it 'returns correct similarity for known vectors' do
      vec_a = [1.0, 2.0, 3.0]
      vec_b = [4.0, 5.0, 6.0]
      expect(host.send(:similarity_cosine, vec_a: vec_a, vec_b: vec_b)).to be_within(0.001).of(0.9746)
    end

    it 'returns 0.0 for zero vectors' do
      vec_a = [0.0, 0.0]
      vec_b = [1.0, 1.0]
      expect(host.send(:similarity_cosine, vec_a: vec_a, vec_b: vec_b)).to eq(0.0)
    end

    it 'returns no match for malformed or unequal persisted vectors' do
      [nil, '', '{bad json', '[1,\"bad\"]', [1.0], [], [Float::NAN, 1.0], [Complex(1, 1), 1.0]].each do |invalid|
        expect(host.send(:similarity_cosine, vec_a: invalid, vec_b: [1.0, 2.0])).to eq(0.0)
      end
    end

    it 'compares JSON vectors and avoids overflowing large finite components' do
      expect(host.send(:similarity_cosine, vec_a: '[1.0,2.0]', vec_b: [1.0, 2.0])).to be_within(0.001).of(1.0)
      expect(host.send(:similarity_cosine, vec_a: [1e300, 1e300], vec_b: [1e300, 1e300])).to be_within(0.001).of(1.0)
    end
  end

  describe 'corroboration threshold' do
    it 'returns true when similarity exceeds threshold' do
      expect(host.send(:similarity_above_corroboration_threshold?, similarity: 0.95)).to be true
    end

    it 'returns false when similarity below threshold' do
      expect(host.send(:similarity_above_corroboration_threshold?, similarity: 0.85)).to be false
    end
  end

  describe 'match classification' do
    it 'returns :corroboration for high similarity same type' do
      result = host.send(:similarity_classify_match, similarity: 0.95, same_content_type: true)
      expect(result).to eq(:corroboration)
    end

    it 'returns :contradiction for high similarity with contradicts relation' do
      result = host.send(:similarity_classify_match, similarity: 0.95, same_content_type: true, contradicts: true)
      expect(result).to eq(:contradiction)
    end

    it 'returns :novel for low similarity' do
      result = host.send(:similarity_classify_match, similarity: 0.5, same_content_type: true)
      expect(result).to eq(:novel)
    end
  end
end
