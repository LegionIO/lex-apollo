# frozen_string_literal: true

require 'legion/extensions/actors/every'
require 'legion/extensions/apollo/runners/contradictions'

module Legion
  module Extensions
    module Apollo
      module Actor
        class ContradictionScanner < Legion::Extensions::Actors::Every
          include Legion::Settings::Helper

          def runner_class    = Legion::Extensions::Apollo::Runners::Contradictions
          def runner_function = 'scan_pending_contradictions'
          def time            = settings[:actors][:contradiction_interval]
          def run_now?        = false
          def use_runner?     = false
          def check_subtask?  = false
          def generate_task?  = false
        end
      end
    end
  end
end
