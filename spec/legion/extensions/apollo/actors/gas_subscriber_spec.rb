# frozen_string_literal: true

require 'spec_helper'

unless defined?(Legion::Extensions::Actors::Subscription)
  module Legion
    module Extensions
      module Actors
        class Subscription; end # rubocop:disable Lint/EmptyClass
      end
    end
  end
end
$LOADED_FEATURES << 'legion/extensions/actors/subscription' unless $LOADED_FEATURES.include?('legion/extensions/actors/subscription')

require 'legion/extensions/apollo/actors/gas_subscriber'

RSpec.describe Legion::Extensions::Apollo::Actor::GasSubscriber do
  subject(:actor) { described_class.new }

  it 'dispatches an audit event through the subscription receiver contract' do
    result = actor.runner_class.public_send(actor.runner_function, messages: [], response_content: nil)

    expect(result).to include(phases_completed: 0)
    expect(result).not_to have_key(:error)
  end

  describe '#enabled?' do
    it 'returns truthy when Gas runner and Transport are defined' do
      stub_const('Legion::Transport', Module.new)
      expect(actor.enabled?).to be_truthy
    end

    it 'returns falsey when Transport is not defined' do
      hide_const('Legion::Transport') if defined?(Legion::Transport)
      expect(actor.enabled?).to be_falsey
    end
  end
end
