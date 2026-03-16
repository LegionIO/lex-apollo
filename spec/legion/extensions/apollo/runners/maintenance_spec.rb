# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/runners/maintenance'

RSpec.describe Legion::Extensions::Apollo::Runners::Maintenance do
  let(:runner) do
    obj = Object.new
    obj.extend(described_class)
    obj
  end

  describe '#force_decay' do
    it 'returns a force_decay payload' do
      result = runner.force_decay(factor: 0.5)
      expect(result[:action]).to eq(:force_decay)
      expect(result[:factor]).to eq(0.5)
    end
  end

  describe '#archive_stale' do
    it 'returns an archive payload with default days' do
      result = runner.archive_stale
      expect(result[:action]).to eq(:archive_stale)
      expect(result[:days]).to eq(90)
    end
  end

  describe '#resolve_dispute' do
    it 'returns a resolve payload' do
      result = runner.resolve_dispute(entry_id: 'uuid-123', resolution: :keep)
      expect(result[:action]).to eq(:resolve_dispute)
      expect(result[:resolution]).to eq(:keep)
    end
  end
end
