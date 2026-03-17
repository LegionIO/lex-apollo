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

  describe '#decay_rate' do
    it 'returns default rate when settings unavailable' do
      expect(maintenance.send(:decay_rate)).to eq(0.998)
    end
  end

  describe '#decay_threshold' do
    it 'returns default threshold when settings unavailable' do
      expect(maintenance.send(:decay_threshold)).to eq(0.1)
    end
  end
end
