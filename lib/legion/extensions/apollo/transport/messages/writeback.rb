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

            def publish_envelope_options(options, **)
              super(options.except(:content_type))
            end

            def publish(options = nil, **)
              raise ArgumentError, 'Invalid Apollo writeback message' unless @valid

              original_options = @options
              @options = @options.merge(options || {}).merge(message_id: SecureRandom.uuid, mandatory: true)
              timeout_ms = @options.fetch(:publish_confirm_timeout_ms, 5000)
              unless timeout_ms.is_a?(Numeric) && timeout_ms.real? && timeout_ms.finite? && timeout_ms.positive?
                raise ArgumentError, 'publish_confirm_timeout_ms must be finite and positive'
              end

              payload = encode_message
              if payload.bytesize > self.class.max_payload_bytes
                raise Legion::Transport::PayloadTooLarge, 'Apollo writeback exceeds the transport payload limit'
              end

              envelope = publish_envelope_options(@options)
              expected_message_id = @options[:message_id]
              returned = false
              confirm_channel = nil
              confirmed = Timeout.timeout(timeout_ms / 1000.0) do
                destination = exchange.cached_instance || exchange.new
                confirm_channel = destination.channel
                destination.on_return do |_delivery, properties, _payload|
                  returned = true if properties.message_id == expected_message_id
                end
                confirm_channel.confirm_select unless confirm_channel.using_publisher_confirmations?
                destination.publish(payload, **envelope)
                confirm_channel.wait_for_confirms
              end
              raise IOError, 'Apollo writeback publication was not accepted' unless confirmed == true && !returned

              { accepted: true, status: :accepted, message_id: expected_message_id }
            rescue Timeout::Error => e
              handle_exception(e, level: :warn, operation: 'apollo.writeback.publish')
              close_confirm_channel(channel: confirm_channel)
              raise
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'apollo.writeback.publish')
              raise
            ensure
              @options = original_options if original_options
            end

            def validate
              raise TypeError, 'content is required' unless @options[:content].is_a?(String)

              @valid = true
            end

            private

            def close_confirm_channel(channel:, **)
              Timeout.timeout(1) { channel.close if channel&.open? }
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'apollo.writeback.close_channel')
            end
          end
        end
      end
    end
  end
end
