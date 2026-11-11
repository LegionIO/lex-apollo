# frozen_string_literal: true

require 'legion/json'

module Legion
  module Extensions
    module Apollo
      module Helpers
        module Similarity
          include Legion::Settings::Helper
          include Legion::Logging::Helper
          include Legion::JSON::Helper

          private

          def similarity_cosine(vec_a:, vec_b:, **)
            left = similarity_parse_vector(vector: vec_a)
            right = similarity_parse_vector(vector: vec_b)
            return 0.0 unless left && right && left.length == right.length

            scale_a = left.max_by(&:abs).abs
            scale_b = right.max_by(&:abs).abs
            return 0.0 if scale_a.zero? || scale_b.zero?

            dot = mag_a = mag_b = 0.0
            left.each_index do |index|
              a = left[index].fdiv(scale_a)
              b = right[index].fdiv(scale_b)
              dot += a * b
              mag_a += a * a
              mag_b += b * b
            end
            (dot / Math.sqrt(mag_a * mag_b)).clamp(-1.0, 1.0)
          end

          def similarity_parse_vector(vector:, **)
            vector = json_parse(vector) if vector.is_a?(String)
            return nil unless vector.is_a?(Array) && !vector.empty?
            return nil unless vector.all? { |value| value.is_a?(Numeric) && value.real? && value.finite? }

            vector
          rescue Legion::JSON::ParseError => e
            handle_exception(e, level: :warn, operation: 'apollo.similarity.parse_vector')
            nil
          end

          def similarity_above_corroboration_threshold?(similarity:, **)
            similarity >= settings[:confidence][:corroboration_similarity]
          end

          def similarity_classify_match(similarity:, same_content_type: true, contradicts: false, **)
            if similarity_above_corroboration_threshold?(similarity: similarity) && same_content_type
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
