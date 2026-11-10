# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/transport/subscription_delivery'

RSpec.describe Legion::Extensions::Apollo::Transport::SubscriptionDelivery do
  subject(:delivery) { Object.new.extend(described_class) }

  let(:runner) { double('ingest runner') }

  before { allow(delivery).to receive(:extension_dispatch_allowed?).and_return(true) }

  it 'raises on an unsuccessful write so the subscriber cannot acknowledge normal completion' do
    allow(runner).to receive(:handle_ingest).and_return(success: false, error: 'database unavailable')

    expect { delivery.send(:dispatch_runner, { content: 'retry me' }, runner, :handle_ingest, false, false) }
      .to raise_error(IOError, /database unavailable/)
  end

  it 'rejects a reported error even when a runner supplies a contradictory success flag' do
    allow(runner).to receive(:handle_ingest).and_return(success: true, error: 'write rejected')

    expect { delivery.send(:dispatch_runner, {}, runner, :handle_ingest, false, false) }
      .to raise_error(IOError, /write rejected/)
  end

  it 'rejects a missing result rather than treating it as a completed write' do
    allow(runner).to receive(:handle_ingest).and_return(nil)

    expect { delivery.send(:dispatch_runner, {}, runner, :handle_ingest, false, false) }
      .to raise_error(IOError, /Apollo delivery failed/)
  end

  it 'leaves quiescing deliveries retryable without invoking the runner' do
    allow(delivery).to receive(:extension_dispatch_allowed?).and_return(false)
    expect(runner).not_to receive(:handle_ingest)

    expect { delivery.send(:dispatch_runner, {}, runner, :handle_ingest, false, false) }
      .to raise_error(IOError, /not accepting new work/)
  end
end
