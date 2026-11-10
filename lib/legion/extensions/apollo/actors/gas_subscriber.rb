# frozen_string_literal: true

require 'legion/extensions/actors/subscription'
require 'legion/extensions/apollo/runners/gas'
require 'legion/extensions/apollo/transport/subscription_delivery'

module Legion
  module Extensions
    module Apollo
      module Actor
        class GasSubscriber < Legion::Extensions::Actors::Subscription
          include Legion::Extensions::Apollo::Transport::SubscriptionDelivery

          def runner_class    = Legion::Extensions::Apollo::Runners::Gas
          def runner_function = 'process'
          def check_subtask?  = false
          def generate_task?  = false
        end
      end
    end
  end
end
