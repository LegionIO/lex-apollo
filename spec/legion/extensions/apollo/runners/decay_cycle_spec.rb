# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/runners/maintenance'

RSpec.describe 'Apollo Decay Cycle' do
  let(:maintenance) { Legion::Extensions::Apollo::Runners::Maintenance }

  before do
    allow(Legion::Data).to receive(:connection).and_return(nil)
    allow(maintenance).to receive(:settings).and_return(Legion::Extensions::Apollo.settings)
  end

  describe '#run_decay_cycle' do
    it 'returns an explicit unavailable error when the database is absent' do
      expect(maintenance.run_decay_cycle).to include(
        success: false, decayed: 0, archived: 0, error: 'apollo_data_not_available'
      )
    end
  end

  describe 'configurable decay parameters' do
    it 'uses the configured power-law alpha' do
      expect(Legion::Extensions::Apollo.settings[:power_law_alpha]).to eq(0.05)
    end

    it 'uses the configured decay threshold' do
      expect(Legion::Extensions::Apollo.settings[:decay_threshold]).to eq(0.05)
    end

    it 'uses the configured minimum age' do
      expect(Legion::Extensions::Apollo.settings[:decay_min_age_hours]).to eq(168)
    end
  end
end
