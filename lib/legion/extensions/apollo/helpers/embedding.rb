# frozen_string_literal: true

module Legion
  module Extensions
    module Apollo
      module Helpers
        module Embedding
          DEFAULT_DIMENSION = 1536

          module_function

          def generate(text:, **)
            return zero_vector unless defined?(Legion::LLM) && Legion::LLM.started?

            result = Legion::LLM.embed(text: text)
            if result.is_a?(Array) && result.any?
              @dimension = result.size
              result
            else
              zero_vector
            end
          end

          def dimension
            @dimension || DEFAULT_DIMENSION
          end

          def zero_vector
            Array.new(dimension, 0.0)
          end
        end
      end
    end
  end
end
