# frozen_string_literal: true

require 'legion/extensions/actors/every'
require 'legion/extensions/apollo/runners/entity_watchdog'

module Legion
  module Extensions
    module Apollo
      module Actor
        class EntityWatchdog < Legion::Extensions::Actors::Every
          include Legion::Settings::Helper

          def runner_class    = Legion::Extensions::Apollo::Runners::EntityWatchdog
          def runner_function = 'scan_and_ingest'
          def time            = settings[:actors][:entity_watchdog_interval]
          def run_now?        = false
          def use_runner?     = false
          def check_subtask?  = false
          def generate_task?  = false
        end
      end
    end
  end
end
