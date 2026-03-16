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

require 'legion/extensions/apollo/runners/expertise'
require 'legion/extensions/apollo/actors/expertise_aggregator'

RSpec.describe Legion::Extensions::Apollo::Actor::ExpertiseAggregator do
  subject(:actor) { described_class.new }

  it 'uses Expertise runner_class' do
    expect(actor.runner_class).to eq(Legion::Extensions::Apollo::Runners::Expertise)
  end

  it 'runs aggregate function' do
    expect(actor.runner_function).to eq('aggregate')
  end

  it 'runs every 1800 seconds' do
    expect(actor.time).to eq(1800)
  end

  it 'does not run immediately' do
    expect(actor.run_now?).to be false
  end

  it 'does not generate tasks' do
    expect(actor.generate_task?).to be false
  end
end
