# frozen_string_literal: true

require 'legion/extensions/actors/subscription'
require_relative '../runners/query_response'

module Legion
  module Extensions
    module Apollo
      module Actor
        class QueryResponder < Legion::Extensions::Actors::Subscription
          def runner_class    = Legion::Extensions::Apollo::Runners::QueryResponse
          def runner_function = 'handle_request'
          def use_runner?     = false
          def check_subtask?  = false
          def generate_task?  = false

          def process_message(message, metadata, delivery_info)
            super.tap do |request|
              request[:reply_to] = metadata.reply_to if metadata.respond_to?(:reply_to) && metadata.reply_to
              request[:correlation_id] = metadata.correlation_id if metadata.respond_to?(:correlation_id) && metadata.correlation_id
            end
          end

          def enabled? # rubocop:disable Legion/Extension/ActorEnabledSideEffects
            defined?(Legion::Extensions::Apollo::Runners::Knowledge) &&
              Legion.const_defined?(:Transport, false)
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.query_responder.enabled')
            false
          end

          private

          def republish_with_retry_count(_delivery_info, metadata, payload, new_count)
            headers = (metadata&.headers || {}).merge(Legion::Extensions::Actors::RetryPolicy::RETRY_COUNT_HEADER => new_count)
            @queue.channel.default_exchange.publish(
              payload, routing_key: @queue.name, headers: headers, content_type: metadata&.content_type,
              content_encoding: metadata&.content_encoding, reply_to: metadata&.reply_to,
              correlation_id: metadata&.correlation_id, persistent: true
            )
            true
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.query_responder.retry')
            false
          end
        end
      end
    end
  end
end
