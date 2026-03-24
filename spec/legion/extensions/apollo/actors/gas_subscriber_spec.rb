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

require 'legion/extensions/apollo/runners/gas'
require 'legion/extensions/apollo/actors/gas_subscriber'

RSpec.describe Legion::Extensions::Apollo::Actor::GasSubscriber do
  subject(:actor) { described_class.new }

  it 'uses Gas runner_class as string' do
    expect(actor.runner_class).to eq('Legion::Extensions::Apollo::Runners::Gas')
  end

  it 'runs process function' do
    expect(actor.runner_function).to eq('process')
  end

  it 'does not generate tasks' do
    expect(actor.generate_task?).to be false
  end

  it 'does not check subtasks' do
    expect(actor.check_subtask?).to be false
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
