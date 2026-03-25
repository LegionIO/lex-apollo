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
            embedding = Helpers::Embedding.generate(text: payload[:content])
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
          rescue StandardError
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
