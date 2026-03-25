# frozen_string_literal: true

require 'legion/transport/message' if defined?(Legion::Transport)

module Legion
  module Extensions
    module Apollo
      module Transport
        module Messages
          class Writeback < Legion::Transport::Message
            def exchange
              Exchanges::Apollo
            end

            def routing_key
              @options[:has_embedding] ? 'apollo.writeback.store' : 'apollo.writeback.vectorize'
            end

            def type
              'apollo_writeback'
            end

            def message
              {
                content:          @options[:content],
                content_type:     @options[:content_type],
                tags:             @options[:tags],
                source_agent:     @options[:source_agent],
                source_channel:   @options[:source_channel],
                submitted_by:     @options[:submitted_by],
                submitted_from:   @options[:submitted_from],
                embedding:        @options[:embedding],
                knowledge_domain: @options[:knowledge_domain],
                context:          @options[:context] || {}
              }.compact
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
