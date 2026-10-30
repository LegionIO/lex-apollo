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

          def process_message(message, metadata, delivery_info, **)
            { identity_principal_id: nil, identity_id: nil, identity_canonical_name: nil }.merge(super(message, metadata, delivery_info))
          end

          def enabled? # rubocop:disable Legion/Extension/ActorEnabledSideEffects
            defined?(Legion::Extensions::Apollo::Runners::Knowledge) &&
              Legion.const_defined?(:Transport, false)
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.ingest.enabled')
            false
          end
        end
      end
    end
  end
end
