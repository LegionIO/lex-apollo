# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/helpers/confidence'

RSpec.describe Legion::Extensions::Apollo::Helpers::Confidence do
  let(:host) { Object.new.extend(described_class) }

  before do
    allow(host).to receive(:settings).and_return(Legion::Extensions::Apollo.default_settings)
  end

  describe 'retrieval confidence boost' do
    it 'adds the configured retrieval boost to confidence' do
      result = host.send(:confidence_apply_retrieval_boost, confidence: 0.5)
      expect(result).to eq(0.52)
    end

    it 'uses the configured retrieval weight' do
      host.send(:settings)[:confidence][:retrieval_boost] = 0.1
      expect(host.send(:confidence_apply_retrieval_boost, confidence: 0.5)).to eq(0.6)
    end

    it 'clamps to 1.0 maximum' do
      result = host.send(:confidence_apply_retrieval_boost, confidence: 0.99)
      expect(result).to eq(1.0)
    end
  end

  describe 'corroboration confidence boost' do
    it 'adds the configured corroboration boost to confidence' do
      result = host.send(:confidence_apply_corroboration_boost, confidence: 0.5)
      expect(result).to eq(0.8)
    end

    it 'clamps to 1.0 maximum' do
      result = host.send(:confidence_apply_corroboration_boost, confidence: 0.9)
      expect(result).to eq(1.0)
    end

    it 'applies half weight for same-source corroboration' do
      result = host.send(:confidence_apply_corroboration_boost, confidence: 0.5, weight: 0.5)
      expect(result).to eq(0.65)
    end
  end
end
