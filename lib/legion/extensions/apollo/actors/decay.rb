# frozen_string_literal: true

require 'legion/extensions/actors/every'
require 'legion/extensions/apollo/runners/maintenance'

module Legion
  module Extensions
    module Apollo
      module Actor
        class Decay < Legion::Extensions::Actors::Every
          include Legion::Settings::Helper

          def runner_class    = Legion::Extensions::Apollo::Runners::Maintenance
          def runner_function = 'run_decay_cycle'
          def time            = settings[:actors][:decay_interval]
          def run_now?        = false
          def use_runner?     = false
          def check_subtask?  = false
          def generate_task?  = false
        end
      end
    end
  end
end
