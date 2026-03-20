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
    it 'returns power-law derived rate when settings unavailable' do
      expected = 1.0 / (1.0 + 0.1) # ~0.909091
      expect(maintenance.send(:decay_rate)).to be_within(0.0001).of(expected)
    end
  end

  describe '#decay_threshold' do
    it 'returns default threshold when settings unavailable' do
      expect(maintenance.send(:decay_threshold)).to eq(0.1)
    end
  end
end
