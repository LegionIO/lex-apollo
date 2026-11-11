# frozen_string_literal: true

require 'legion/extensions/actors/subscription'
require 'legion/extensions/apollo/runners/writeback'
require 'legion/extensions/apollo/transport/subscription_delivery'

module Legion
  module Extensions
    module Apollo
      module Actor
        class WritebackVectorize < Legion::Extensions::Actors::Subscription
          include Legion::Extensions::Apollo::Helpers::Capability
          include Legion::Extensions::Apollo::Transport::SubscriptionDelivery

          def runner_class(**) = Legion::Extensions::Apollo::Runners::Writeback
          def runner_function = 'handle_vectorize'
          def use_runner?     = false
          def check_subtask?  = false
          def generate_task?  = false

          def enabled?(**) # rubocop:disable Legion/Extension/ActorEnabledSideEffects
            capability_can_embed?
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.writeback_vectorize.enabled')
            false
          end
        end
      end
    end
  end
end
