# frozen_string_literal: true

require 'legion/extensions/actors/subscription'
require_relative '../runners/writeback'

module Legion
  module Extensions
    module Apollo
      module Actor
        class WritebackVectorize < Legion::Extensions::Actors::Subscription
          def runner_class(**) = Legion::Extensions::Apollo::Runners::Writeback
          def runner_function = 'handle_vectorize'
          def check_subtask?  = false
          def generate_task?  = false
          def use_runner?(**) = false

          def enabled?(**) # rubocop:disable Legion/Extension/ActorEnabledSideEffects
            Legion.const_defined?(:Transport, false) && Legion::Extensions::Apollo::Helpers::Capability.can_embed?
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.writeback_vectorize.enabled')
            false
          end
        end
      end
    end
  end
end
