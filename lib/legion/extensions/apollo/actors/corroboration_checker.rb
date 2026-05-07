# frozen_string_literal: true

require 'legion/extensions/actors/every'
require_relative '../runners/maintenance'

module Legion
  module Extensions
    module Apollo
      module Actor
        class CorroborationChecker < Legion::Extensions::Actors::Every
          include Legion::Settings::Helper

          def runner_class    = Legion::Extensions::Apollo::Runners::Maintenance
          def runner_function = 'check_corroboration'
          def time            = settings[:actors][:corroboration_interval]
          def run_now?        = false
          def use_runner?     = false
          def check_subtask?  = false
          def generate_task?  = false
        end
      end
    end
  end
end
