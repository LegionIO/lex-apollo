# frozen_string_literal: true

require_relative 'confidence'

module Legion
  module Extensions
    module Apollo
      module Helpers
        module Similarity
          extend Legion::Logging::Helper
          extend Legion::JSON::Helper

          module_function

          def cosine_similarity(vec_a:, vec_b:, **)
            vec_a = parse_vector(vector: vec_a)
            vec_b = parse_vector(vector: vec_b)
            return 0.0 unless vec_a && vec_b && vec_a.length == vec_b.length

            scale_a = vec_a.max_by(&:abs).abs
            scale_b = vec_b.max_by(&:abs).abs
            return 0.0 if scale_a.zero? || scale_b.zero?

            dot = mag_a = mag_b = 0.0
            vec_a.each_index do |index|
              a = vec_a[index].fdiv(scale_a)
              b = vec_b[index].fdiv(scale_b)
              dot += a * b
              mag_a += a * a
              mag_b += b * b
            end
            (dot / Math.sqrt(mag_a * mag_b)).clamp(-1.0, 1.0)
          end

          def parse_vector(vector:, **)
            vector = json_parse(vector) if vector.is_a?(String)
            return nil unless vector.is_a?(Array) && !vector.empty?
            return nil unless vector.all? { |value| value.is_a?(Numeric) && value.real? && value.finite? }

            vector
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.similarity.parse_vector')
            nil
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
