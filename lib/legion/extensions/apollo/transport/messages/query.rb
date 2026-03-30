# frozen_string_literal: true

require 'legion/transport/message'

module Legion
  module Extensions
    module Apollo
      module Transport
        module Messages
          class Query < Legion::Transport::Message
            def exchange
              Exchanges::Apollo
            end

            def routing_key
              'legion.apollo.query'
            end

            def message
              {
                action:         @options[:action],
                query:          @options[:query],
                entry_id:       @options[:entry_id],
                limit:          @options[:limit],
                min_confidence: @options[:min_confidence],
                status:         @options[:status],
                tags:           @options[:tags],
                relation_types: @options[:relation_types],
                depth:          @options[:depth],
                reply_to:       @options[:reply_to],
                correlation_id: @options[:correlation_id]
              }.compact
            end

            def type
              'apollo_query'
            end
          end
        end
      end
    end
  end
end
