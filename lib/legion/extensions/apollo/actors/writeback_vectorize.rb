# frozen_string_literal: true

require 'legion/extensions/actors/subscription' if defined?(Legion::Extensions::Actors::Subscription)

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
            result = Legion::LLM::Embeddings.generate(text: payload[:content])
            vector = result.is_a?(Hash) ? result[:vector] : result
            embedding = vector.is_a?(Array) && vector.any? ? vector : Array.new(1024, 0.0)
            enriched = payload.merge(embedding: embedding)

            if Helpers::Capability.can_write?
              Runners::Knowledge.handle_ingest(**enriched)
            else
              Transport::Messages::Writeback.new(
                **enriched, has_embedding: true
              ).publish
            end

            { success: true, action: :vectorized }
          rescue StandardError => e
            { success: false, error: e.message }
          end

          def enabled?
            defined?(Legion::Transport) && Helpers::Capability.can_embed?
          rescue StandardError => e
            log.warn("WritebackVectorize enabled? check failed: #{e.message}")
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
