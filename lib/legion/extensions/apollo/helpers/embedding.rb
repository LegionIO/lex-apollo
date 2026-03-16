# frozen_string_literal: true

module Legion
  module Extensions
    module Apollo
      module Helpers
        module Embedding
          DIMENSION = 1536

          module_function

          def generate(text:, **)
            return Array.new(DIMENSION, 0.0) unless defined?(Legion::LLM) && Legion::LLM.started?

            result = Legion::LLM.embed(text: text)
            result.is_a?(Array) && result.size == DIMENSION ? result : Array.new(DIMENSION, 0.0)
          end
        end
      end
    end
  end
end
