# frozen_string_literal: true

require 'legion/extensions/actors/subscription'
require 'legion/extensions/apollo/runners/knowledge'
require 'legion/extensions/apollo/transport/subscription_delivery'

module Legion
  module Extensions
    module Apollo
      module Actor
        class Ingest < Legion::Extensions::Actors::Subscription
          include Legion::Extensions::Apollo::Transport::SubscriptionDelivery

          def runner_class    = Legion::Extensions::Apollo::Runners::Knowledge
          def runner_function = 'handle_ingest'
          def check_subtask?  = false
          def generate_task?  = false

          def process_message(message, metadata, delivery_info, **)
            { identity_principal_id: nil, identity_id: nil, identity_canonical_name: nil }.merge(super(message, metadata, delivery_info))
          end
        end
      end
    end
  end
end
