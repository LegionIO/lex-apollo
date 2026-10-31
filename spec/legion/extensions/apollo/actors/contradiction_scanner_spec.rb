# frozen_string_literal: true

require 'spec_helper'

$LOADED_FEATURES << 'legion/extensions/actors/every' unless $LOADED_FEATURES.include?('legion/extensions/actors/every')
require 'legion/extensions/apollo/actors/contradiction_scanner'

RSpec.describe Legion::Extensions::Apollo::Actor::ContradictionScanner do
  subject(:scanner) { described_class.new }

  before { described_class.drain }
  after { described_class.drain }

  it 'processes queued work through the actual private detector' do
    described_class.enqueue(entry_id: 'no-vector')

    expect(scanner.scan_pending_contradictions).to eq(processed: 1, failed: 0)
    expect(described_class.pending_count).to eq(0)
  end

  it 'retains a failed item, processes later work, and succeeds when the database recovers' do
    entry_model = double('ApolloEntry')
    stub_const('Legion::Data::Model::ApolloEntry', entry_model)
    allow(entry_model).to receive(:[]).with('retry-me').and_raise(Sequel::Error, 'database unavailable')
    allow(entry_model).to receive(:[]).with('completed').and_return(nil)
    described_class.enqueue(entry_id: 'retry-me')
    described_class.enqueue(entry_id: 'completed')

    expect(scanner.scan_pending_contradictions).to eq(processed: 1, failed: 1)
    expect(described_class.pending_count).to eq(1)
    retained = described_class.queue.pop(true)
    expect(retained[:entry_id]).to eq('retry-me')
    described_class.enqueue(**retained)

    allow(entry_model).to receive(:[]).with('retry-me').and_return(nil)
    expect(scanner.scan_pending_contradictions).to eq(processed: 1, failed: 0)
    expect(described_class.pending_count).to eq(0)
  end
end
