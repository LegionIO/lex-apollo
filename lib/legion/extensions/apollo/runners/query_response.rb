# frozen_string_literal: true

require 'legion/json'
require 'securerandom'
require 'timeout'
require 'legion/transport/helper'
require_relative 'knowledge'

module Legion
  module Extensions
    module Apollo
      module Runners
        module QueryResponse
          extend Legion::Logging::Helper
          extend Legion::Transport::Helper
          extend self

          ACTIONS = { 'query' => :handle_query, 'retrieve' => :retrieve_relevant, 'traverse' => :handle_traverse }.freeze

          def handle_request(action: 'query', reply_to: nil, correlation_id: nil, **request)
            function = ACTIONS[action.to_s]
            error = query_response_input_error(action: action, request: request) if function
            result = if function.nil?
                       { success: false, error: :invalid_action }
                     elsif error
                       { success: false, error: :invalid_request, message: error }
                     else
                       request[:requesting_principal_id] ||= 0
                       query_response_knowledge.public_send(function, **request)
                     end
            query_response_publish(result: result, reply_to: reply_to, correlation_id: correlation_id) unless reply_to.nil?
            result
          end

          private

          def query_response_knowledge
            @query_response_knowledge ||= Object.new.extend(Legion::Extensions::Apollo::Runners::Knowledge)
          end

          def query_response_input_error(action:, request:, **)
            input_error = if action.to_s == 'traverse'
                            query_response_traversal_error(request: request)
                          else
                            query_response_search_error(request: request)
                          end
            return input_error if input_error

            return 'tag_match must be any or all' if request.key?(:tag_match) && !%w[any all].include?(request[:tag_match].to_s)
            return 'exclude_source_agents must be an array' if !request[:exclude_source_agents].nil? && !request[:exclude_source_agents].is_a?(Array)

            principal = request[:requesting_principal_id]
            return 'requesting_principal_id must be a nonnegative integer' if !principal.nil? && (!principal.is_a?(Integer) || principal.negative?)

            nil
          end

          def query_response_traversal_error(request:, **)
            entry_id = request[:entry_id]
            valid_id = (entry_id.is_a?(String) && !entry_id.empty?) || (entry_id.is_a?(Integer) && entry_id.positive?)
            return 'entry_id must be a nonempty string or positive integer' unless valid_id
            return 'depth must be a nonnegative integer' if request.key?(:depth) && (!request[:depth].is_a?(Integer) || request[:depth].negative?)
            return 'relation_types must be an array' if !request[:relation_types].nil? && !request[:relation_types].is_a?(Array)

            nil
          end

          def query_response_search_error(request:, **)
            return 'query must be a string' unless request[:query].is_a?(String)
            return 'limit must be a positive integer' if request.key?(:limit) && (!request[:limit].is_a?(Integer) || !request[:limit].positive?)

            if request.key?(:min_confidence)
              confidence = request[:min_confidence]
              return 'min_confidence must be between zero and one' unless confidence.is_a?(Numeric) && confidence.finite? && confidence.between?(0, 1)
            end
            nil
          end

          def query_response_publish(result:, reply_to:, correlation_id:, **)
            raise ArgumentError, 'reply_to must be a nonempty string' unless reply_to.is_a?(String) && !reply_to.empty?

            channel = transport_channel
            exchange = channel.default_exchange
            message_id = SecureRandom.uuid
            returned = false
            exchange.on_return do |_delivery, properties, _payload|
              returned = true if properties.message_id == message_id
            end
            confirmed = Timeout.timeout(5) do
              channel.confirm_select unless channel.using_publisher_confirmations?
              exchange.publish(Legion::JSON.dump(result), routing_key: reply_to, correlation_id: correlation_id,
                                message_id: message_id, content_type: 'application/json', content_encoding: 'identity', mandatory: true)
              channel.wait_for_confirms
            end
            raise IOError, 'Apollo reply publication failed' unless confirmed == true && !returned
          rescue Timeout::Error => e
            handle_exception(e, level: :warn, operation: 'apollo.query_response.publish')
            begin
              Timeout.timeout(1) { channel.close if channel&.open? }
            rescue StandardError => close_error
              handle_exception(close_error, level: :warn, operation: 'apollo.query_response.close_channel')
            end
            raise
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.query_response.publish')
            raise
          end
        end
      end
    end
  end
end
