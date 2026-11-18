# frozen_string_literal: true

require 'spec_helper'

$LOADED_FEATURES << 'legion/extensions/actors/subscription' unless $LOADED_FEATURES.include?('legion/extensions/actors/subscription')
require 'legion/extensions/apollo/actors/gas_subscriber'

RSpec.describe Legion::Extensions::Apollo::Actor::GasSubscriber do
  subject(:actor) { described_class.allocate }

  before { allow(actor).to receive(:settings).and_return(gas: { enabled: false }) }

  it 'does not prepare a consumer when GAS is disabled' do
    expect(actor).not_to receive(:create_dedicated_channel)

    expect(actor.prepare).to be_nil
  end

  it 'does not activate a consumer when GAS is disabled' do
    expect(actor).not_to receive(:subscribe)

    expect(actor.activate).to be_nil
  end
end
