# frozen_string_literal: true

require 'legion/transport/message'

module Legion
  module Extensions
    module Apollo
      module Transport
        module Messages
          class Writeback < Legion::Transport::Message
            def exchange
              Legion::Extensions::Apollo::Transport::Exchanges::Apollo
            end

            def routing_key
              @options[:has_embedding] ? 'legion.apollo.writeback.store' : 'legion.apollo.writeback.vectorize'
            end

            def type
              'apollo_writeback'
            end

            def message
              { context: {} }.merge(
                @options.slice(:content, :content_type, :tags, :source_agent, :source_provider,
                               :source_channel, :knowledge_domain, :submitted_by, :submitted_from,
                               :content_hash, :context, :access_scope, :identity_principal_id,
                               :identity_id, :identity_canonical_name, :embedding)
              )
            end

            def publish_envelope_options(options, **)
              super(options.except(:content_type))
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
