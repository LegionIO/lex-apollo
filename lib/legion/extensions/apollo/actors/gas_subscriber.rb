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
          def use_runner?     = false

          def enabled?
            defined?(Legion::Extensions::Apollo::Runners::Gas) &&
              defined?(Legion::Transport)
          rescue StandardError => e
            log.warn("GasSubscriber enabled? check failed: #{e.message}")
            false
          end

          def create_queue
            return if queues.const_defined?(:GasSubscriber, false)

            queues.const_set(:GasSubscriber, Apollo::Transport::Queues::GasSubscriber) unless queues.const_defined?(:GasSubscriber, false)
            exchange_object = Apollo::Transport::Exchanges::LlmAudit.new
            queue_object = Apollo::Transport::Queues::GasSubscriber.new
            queue_object.bind(exchange_object, routing_key: 'llm.audit.complete')
          end
        end
      end
    end
  end
end
