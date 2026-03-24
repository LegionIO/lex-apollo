# frozen_string_literal: true

require 'legion/extensions/actors/every'
require_relative '../runners/maintenance'

module Legion
  module Extensions
    module Apollo
      module Actor
        class Decay < Legion::Extensions::Actors::Every
          def runner_class    = Legion::Extensions::Apollo::Runners::Maintenance
          def runner_function = 'run_decay_cycle'
          def time            = (defined?(Legion::Settings) && Legion::Settings.dig(:apollo, :actors, :decay_interval)) || 3600
          def run_now?        = false
          def use_runner?     = false
          def check_subtask?  = false
          def generate_task?  = false
        end
      end
    end
  end
end
