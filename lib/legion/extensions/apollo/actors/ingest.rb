# frozen_string_literal: true

require 'legion/extensions/actors/subscription'

module Legion
  module Extensions
    module Apollo
      module Actor
        class Ingest < Legion::Extensions::Actors::Subscription
          def runner_class    = 'Legion::Extensions::Apollo::Runners::Knowledge'
          def runner_function = 'handle_ingest'
          def check_subtask?  = false
          def generate_task?  = false

          def enabled? # rubocop:disable Legion/Extension/ActorEnabledSideEffects
            defined?(Legion::Extensions::Apollo::Runners::Knowledge) &&
              Legion.const_defined?(:Transport, false)
          rescue StandardError => e
            log.warn("Ingest enabled? check failed: #{e.message}")
            false
          end
        end
      end
    end
  end
end
