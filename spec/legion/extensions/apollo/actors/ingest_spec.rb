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

require 'legion/extensions/apollo/runners/knowledge'
require 'legion/extensions/apollo/actors/ingest'

RSpec.describe Legion::Extensions::Apollo::Actor::Ingest do
  subject(:actor) { described_class.new }

  it 'uses Knowledge runner_class as string' do
    expect(actor.runner_class).to eq('Legion::Extensions::Apollo::Runners::Knowledge')
  end

  it 'runs handle_ingest function' do
    expect(actor.runner_function).to eq('handle_ingest')
  end

  it 'does not generate tasks' do
    expect(actor.generate_task?).to be false
  end
end
