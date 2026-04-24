# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Apollo Decay Cycle' do
  let(:maintenance) { Object.new.extend(Legion::Extensions::Apollo::Runners::Maintenance) }

  describe '#run_decay_cycle' do
    it 'returns zeros when db unavailable' do
      result = maintenance.run_decay_cycle
      expect(result).to eq({ decayed: 0, archived: 0 })
    end
  end

  describe 'configurable decay parameters' do
    it 'returns POWER_LAW_ALPHA as default' do
      expect(Legion::Extensions::Apollo::Helpers::Confidence.power_law_alpha).to eq(0.05)
    end

    it 'returns default decay threshold' do
      expect(Legion::Extensions::Apollo::Helpers::Confidence.decay_threshold).to eq(0.05)
    end

    it 'returns default decay minimum age hours' do
      expect(Legion::Extensions::Apollo::Helpers::Confidence.decay_min_age_hours).to eq(168)
    end
  end
end
