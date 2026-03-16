# frozen_string_literal: true

require_relative 'confidence'

module Legion
  module Extensions
    module Apollo
      module Helpers
        module Similarity
          module_function

          def cosine_similarity(vec_a:, vec_b:, **)
            dot = vec_a.zip(vec_b).sum { |x, y| x * y }
            mag_a = Math.sqrt(vec_a.sum { |x| x**2 })
            mag_b = Math.sqrt(vec_b.sum { |x| x**2 })
            return 0.0 if mag_a.zero? || mag_b.zero?

            dot / (mag_a * mag_b)
          end

          def above_corroboration_threshold?(similarity:, **)
            similarity >= Confidence::CORROBORATION_SIMILARITY_THRESHOLD
          end

          def classify_match(similarity:, same_content_type: true, contradicts: false, **)
            if above_corroboration_threshold?(similarity: similarity) && same_content_type
              contradicts ? :contradiction : :corroboration
            else
              :novel
            end
          end
        end
      end
    end
  end
end
