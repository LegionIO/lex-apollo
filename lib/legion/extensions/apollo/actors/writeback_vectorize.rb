# frozen_string_literal: true

require 'legion/extensions/actors/subscription'

module Legion
  module Extensions
    module Apollo
      module Actor
        class WritebackVectorize < Legion::Extensions::Actors::Subscription
          def runner_class    = self.class
          def runner_function = 'handle_vectorize'
          def check_subtask?  = false
          def generate_task?  = false

          def handle_vectorize(payload)
            payload = symbolize(payload)
            log.debug("WritebackVectorize handle_vectorize content_length=#{payload[:content].to_s.length} content_type=#{payload[:content_type] || 'nil'}")
            result = Legion::LLM::Call::Embeddings.generate(text: payload[:content])
            vector = result.is_a?(Hash) ? result[:vector] : result
            embedding = vector.is_a?(Array) && vector.any? ? vector : Array.new(1024, 0.0)
            log.debug("WritebackVectorize embedding_dimensions=#{embedding.length} vector_generated=#{vector.is_a?(Array) && vector.any?}")
            enriched = payload.merge(embedding: embedding)

            if Helpers::Capability.can_write?
              log.debug('WritebackVectorize route=direct_ingest')
              Runners::Knowledge.handle_ingest(**enriched)
            else
              log.debug('WritebackVectorize route=transport_writeback')
              Transport::Messages::Writeback.new(
                **enriched, has_embedding: true
              ).publish
            end

            log.info('WritebackVectorize completed action=vectorized')
            { success: true, action: :vectorized }
          rescue StandardError => e
            handle_exception(e, level: :error, operation: 'apollo.writeback_vectorize.handle_vectorize')
            { success: false, error: e.message }
          end

          def enabled? # rubocop:disable Legion/Extension/ActorEnabledSideEffects
            Legion.const_defined?(:Transport, false) && Helpers::Capability.can_embed?
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.writeback_vectorize.enabled')
            false
          end

          private

          def symbolize(hash)
            hash.transform_keys(&:to_sym)
          end
        end
      end
    end
  end
end
