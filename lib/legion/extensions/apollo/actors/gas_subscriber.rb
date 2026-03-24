# frozen_string_literal: true

require 'legion/extensions/actors/subscription' if defined?(Legion::Extensions::Actors::Subscription)

module Legion
  module Extensions
    module Apollo
      module Actor
        class GasSubscriber < Legion::Extensions::Actors::Subscription
          def runner_class    = 'Legion::Extensions::Apollo::Runners::Gas'
          def runner_function = 'process'
          def check_subtask?  = false
          def generate_task?  = false

          def enabled?
            defined?(Legion::Extensions::Apollo::Runners::Gas) &&
              defined?(Legion::Transport)
          rescue StandardError
            false
          end
        end
      end
    end
  end
end
