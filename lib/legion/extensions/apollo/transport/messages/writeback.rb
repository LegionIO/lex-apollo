# frozen_string_literal: true

require 'legion/transport/message'
require 'securerandom'
require 'timeout'

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

            def message(**)
              { context: {} }.merge(
                @options.slice(:content, :content_type, :tags, :source_agent, :source_provider,
                               :source_channel, :knowledge_domain, :submitted_by, :submitted_from,
                               :content_hash, :context, :access_scope, :identity_principal_id,
                               :identity_id, :identity_canonical_name, :embedding, :embedding_provenance,
                               :source_model, :model, :provider, :instance, :dimensions, :reply_to, :correlation_id)
              )
            end

            def publish_envelope_options(options:, **)
              super(options: options.except(:content_type))
            end

            def publish(options = nil, **)
              raise ArgumentError, 'Invalid Apollo writeback message' unless @valid

              publication = options || {}
              timeout_ms = publication.fetch(:publish_confirm_timeout_ms) { @options.fetch(:publish_confirm_timeout_ms, 5000) }
              unless timeout_ms.is_a?(Numeric) && timeout_ms.real? && timeout_ms.finite? && timeout_ms.positive?
                raise ArgumentError, 'publish_confirm_timeout_ms must be finite and positive'
              end

              result = super(publication.merge(message_id: SecureRandom.uuid, mandatory: true,
                                               publisher_confirm: true, spool: false, return_result: true))
              return result if result[:accepted] == true

              raise Timeout::Error, 'Apollo writeback confirmation timed out' if result[:status] == :confirm_timeout

              raise IOError, result[:error] || "Apollo writeback publication was not accepted: #{result[:status]}"
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'apollo.writeback.publish')
              raise
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
