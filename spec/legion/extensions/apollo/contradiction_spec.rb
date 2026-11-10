# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/runners/contradictions'

RSpec.describe Legion::Extensions::Apollo::Runners::Contradictions do
  before { described_class.const_get(:PENDING_ENTRIES, false).clear }

  after { described_class.const_get(:PENDING_ENTRIES, false).clear }

  it 'queues entry IDs and consumes them after successful scanning' do
    allow(described_class).to receive(:contradictions_detect).and_return(success: true, contradictions: [])

    queued = described_class.enqueue(entry_id: 41)
    result = described_class.scan_pending_contradictions

    expect(queued).to include(success: true, queued: true, entry_id: 41, pending: 1)
    expect(result).to eq(success: true, processed: 1, failed: 0)
    expect(described_class).to have_received(:contradictions_detect).with(entry_id: 41)
    expect(described_class.scan_pending_contradictions).to eq(success: true, processed: 0, failed: 0)
  end

  it 'requeues failed entries while consuming independent successful work' do
    allow(described_class).to receive(:contradictions_detect) do |entry_id:|
      raise Sequel::Error, 'temporary database failure' if entry_id == 41

      { success: true, contradictions: [] }
    end
    described_class.enqueue(entry_id: 41)
    described_class.enqueue(entry_id: 42)

    first = described_class.scan_pending_contradictions

    expect(first).to eq(success: false, processed: 1, failed: 1)
    expect(described_class.scan_pending_contradictions).to eq(success: false, processed: 0, failed: 1)

    allow(described_class).to receive(:contradictions_detect).and_return(success: true, contradictions: [])

    expect(described_class.scan_pending_contradictions).to eq(success: true, processed: 1, failed: 0)
  end
end
