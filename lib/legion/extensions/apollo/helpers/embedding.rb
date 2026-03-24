# frozen_string_literal: true

module Legion
  module Extensions
    module Apollo
      module Helpers
        module Embedding
          DEFAULT_DIMENSION = 1536

          module_function

          def generate(text:, **)
            unless defined?(Legion::LLM) && Legion::LLM.started?
              Legion::Logging.debug('[apollo] embedding fallback: LLM not started') if defined?(Legion::Logging)
              return zero_vector
            end

            result = Legion::LLM.embed(text)
            vector = result.is_a?(Hash) ? result[:vector] : result
            if vector.is_a?(Array) && vector.any?
              @dimension = vector.size
              vector
            else
              Legion::Logging.warn('[apollo] embedding fallback: LLM returned no vector') if defined?(Legion::Logging)
              zero_vector
            end
          end

          def dimension
            @dimension || configured_dimension
          end

          def configured_dimension
            return DEFAULT_DIMENSION unless defined?(Legion::Settings) && !Legion::Settings[:apollo].nil?

            Legion::Settings[:apollo].dig(:embedding, :dimension) || DEFAULT_DIMENSION
          rescue StandardError
            DEFAULT_DIMENSION
          end

          def zero_vector
            Array.new(dimension, 0.0)
          end
        end
      end
    end
  end
end
