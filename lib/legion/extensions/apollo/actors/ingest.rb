# frozen_string_literal: true

require 'legion/extensions/actors/subscription' if defined?(Legion::Extensions::Actors::Subscription)

module Legion
  module Extensions
    module Apollo
      module Actor
        class Ingest < Legion::Extensions::Actors::Subscription
          def runner_class    = 'Legion::Extensions::Apollo::Runners::Knowledge'
          def runner_function = 'handle_ingest'
          def check_subtask?  = false
          def generate_task?  = false

          def enabled?
            defined?(Legion::Extensions::Apollo::Runners::Knowledge) &&
              defined?(Legion::Transport)
          rescue StandardError
            false
          end
        end
      end
    end
  end
end
