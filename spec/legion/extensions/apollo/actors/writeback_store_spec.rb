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

require 'legion/extensions/apollo/helpers/capability'
require 'legion/extensions/apollo/runners/knowledge'
require 'legion/extensions/apollo/actors/writeback_store'

RSpec.describe Legion::Extensions::Apollo::Actor::WritebackStore do
  subject(:actor) { described_class.new }

  describe '#runner_class' do
    it 'returns Knowledge runner string' do
      expect(actor.runner_class).to eq('Legion::Extensions::Apollo::Runners::Knowledge')
    end
  end

  describe '#runner_function' do
    it 'returns handle_ingest' do
      expect(actor.runner_function).to eq('handle_ingest')
    end
  end

  describe '#check_subtask?' do
    it { expect(actor.check_subtask?).to be false }
  end

  describe '#generate_task?' do
    it { expect(actor.generate_task?).to be false }
  end
end
