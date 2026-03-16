# frozen_string_literal: true

require 'spec_helper'

unless defined?(Legion::Extensions::Actors::Every)
  module Legion
    module Extensions
      module Actors
        class Every; end # rubocop:disable Lint/EmptyClass
      end
    end
  end
end
$LOADED_FEATURES << 'legion/extensions/actors/every' unless $LOADED_FEATURES.include?('legion/extensions/actors/every')

require 'legion/extensions/apollo/runners/maintenance'
require 'legion/extensions/apollo/actors/decay'

RSpec.describe Legion::Extensions::Apollo::Actor::Decay do
  subject(:actor) { described_class.new }

  it 'uses Maintenance runner_class' do
    expect(actor.runner_class).to eq(Legion::Extensions::Apollo::Runners::Maintenance)
  end

  it 'runs force_decay function' do
    expect(actor.runner_function).to eq('force_decay')
  end

  it 'runs every 3600 seconds' do
    expect(actor.time).to eq(3600)
  end

  it 'does not run immediately' do
    expect(actor.run_now?).to be false
  end

  it 'does not use runner framework' do
    expect(actor.use_runner?).to be false
  end

  it 'does not generate tasks' do
    expect(actor.generate_task?).to be false
  end
end
