# frozen_string_literal: true

module Legion
  module Extensions
    module Apollo
      module Helpers
        module Confidence
          INITIAL_CONFIDENCE = 0.5
          CORROBORATION_BOOST = 0.3
          RETRIEVAL_BOOST = 0.02
          POWER_LAW_ALPHA = 0.5
          DECAY_THRESHOLD = 0.1
          CORROBORATION_SIMILARITY_THRESHOLD = 0.9
          WRITE_CONFIDENCE_GATE = 0.6
          WRITE_NOVELTY_GATE = 0.3
          STALE_DAYS = 90
          CONTENT_TYPES = %i[fact concept procedure association observation].freeze
          STATUSES = %w[candidate confirmed disputed decayed archived].freeze
          RELATION_TYPES = %w[is_a has_a part_of causes similar_to contradicts supersedes depends_on].freeze

          module_function

          def apply_decay(confidence:, age_hours: nil, alpha: POWER_LAW_ALPHA, **)
            if age_hours
              [confidence * ((age_hours.clamp(0, Float::INFINITY) + 2.0)**(-alpha)) / ((age_hours.clamp(0, Float::INFINITY) + 1.0)**(-alpha)), 0.0].max
            else
              factor = 1.0 / (1.0 + alpha)
              [confidence * factor, 0.0].max
            end
          end

          def apply_retrieval_boost(confidence:, **)
            [confidence + RETRIEVAL_BOOST, 1.0].min
          end

          def apply_corroboration_boost(confidence:, weight: 1.0, **)
            [confidence + (CORROBORATION_BOOST * weight), 1.0].min
          end

          def decayed?(confidence:, **)
            confidence < DECAY_THRESHOLD
          end

          def meets_write_gate?(confidence:, novelty:, **)
            confidence > WRITE_CONFIDENCE_GATE && novelty > WRITE_NOVELTY_GATE
          end
        end
      end
    end
  end
end
