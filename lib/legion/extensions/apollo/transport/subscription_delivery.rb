# frozen_string_literal: true

module Legion
  module Extensions
    module Apollo
      module Transport
        module SubscriptionDelivery
          private

          def dispatch_runner(message, runner_cls, function, _check_subtask, _generate_task)
            raise IOError, 'Apollo is not accepting new work' unless extension_dispatch_allowed?

            result = runner_cls.public_send(function, **message)
            raise IOError, "Apollo delivery failed: #{result.inspect}" unless result.is_a?(Hash) && result[:success] != false && !result[:error]

            result
          end

          def reject_or_retry(delivery_info, metadata, payload)
            retry_count = Legion::Extensions::Actors::RetryPolicy.extract_retry_count(headers: metadata&.headers)
            threshold = Legion::Extensions::Actors::RetryPolicy.retry_threshold
            unless Legion::Extensions::Actors::RetryPolicy.should_retry?(retry_count: retry_count, threshold: threshold)
              log.warn("Apollo delivery exhausted #{retry_count} retries")
              return @queue.reject(delivery_info.delivery_tag, requeue: false)
            end

            base_delay = Legion::Settings.dig(:fleet, :transport, :retry_base_delay_seconds) || 1
            max_delay = Legion::Settings.dig(:fleet, :transport, :retry_max_delay_seconds) || 30
            sleep([base_delay * (2**retry_count), max_delay].min)
            if republish_with_retry_count(delivery_info, metadata, payload, retry_count + 1)
              @queue.acknowledge(delivery_info.delivery_tag)
            else
              @queue.reject(delivery_info.delivery_tag, requeue: false)
            end
          end
        end
      end
    end
  end
end
