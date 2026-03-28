# frozen_string_literal: true

require 'legion/transport/message' if defined?(Legion::Transport)

module Legion
  module Extensions
    module Apollo
      module Transport
        module Messages
          class Ingest < Legion::Transport::Message
            def exchange
              Exchanges::Apollo
            end

            def routing_key
              'legion.apollo.ingest'
            end

            def message
              {
                content:      @options[:content],
                content_type: @options[:content_type],
                tags:         @options[:tags],
                source_agent: @options[:source_agent],
                context:      @options[:context] || {}
              }
            end

            def type
              'apollo_ingest'
            end

            def validate
              raise TypeError, 'content is required' unless @options[:content].is_a?(String)

              @valid = true
            end
          end
        end
      end
    end
  end
end
