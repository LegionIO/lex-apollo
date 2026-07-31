# frozen_string_literal: true

module Legion
  module Extensions
    module Apollo
      module Helpers
        module Confidence
          extend Legion::Logging::Helper
          extend Legion::Settings::Helper

          INITIAL_CONFIDENCE = 0.5
          CORROBORATION_BOOST = 0.3
          RETRIEVAL_BOOST = 0.02
          POWER_LAW_ALPHA = 0.05
          DECAY_THRESHOLD = 0.05
          CORROBORATION_SIMILARITY_THRESHOLD = 0.9
          WRITE_CONFIDENCE_GATE = 0.6
          WRITE_NOVELTY_GATE = 0.3
          STALE_DAYS = 90
          DECAY_MIN_AGE_HOURS = 168
          CONTENT_TYPES = %i[fact concept procedure association observation].freeze
          STATUSES = %w[candidate confirmed disputed decayed archived].freeze
          RELATION_TYPES = %w[is_a has_a part_of causes similar_to contradicts supersedes depends_on].freeze

          module_function

          def initial_confidence     = settings[:confidence][:initial]
          def corroboration_boost    = settings[:confidence][:corroboration_boost]
          def retrieval_boost        = settings[:confidence][:retrieval_boost]
          def power_law_alpha        = settings[:power_law_alpha]
          def decay_threshold        = settings[:decay_threshold]
          def write_confidence_gate  = settings[:confidence][:write_gate]
          def write_novelty_gate     = settings[:confidence][:novelty_gate]
          def stale_days             = settings[:stale_days]
          def decay_min_age_hours    = settings[:decay_min_age_hours]

          def corroboration_similarity_threshold
            settings[:confidence][:corroboration_similarity]
          end

          def apply_decay(confidence:, age_hours: nil, alpha: power_law_alpha, **)
            return confidence if age_hours && age_hours < decay_min_age_hours

            if age_hours
              age_days = age_hours / 24.0
              [confidence * ((age_days.clamp(1, Float::INFINITY) + 1.0)**(-alpha)) / (age_days.clamp(1, Float::INFINITY)**(-alpha)), 0.0].max
            else
              factor = 1.0 / (1.0 + alpha)
              [confidence * factor, 0.0].max
            end
          end

          def apply_retrieval_boost(confidence:, **)
            [confidence + retrieval_boost, 1.0].min
          end

          def apply_corroboration_boost(confidence:, weight: 1.0, **)
            [confidence + (corroboration_boost * weight), 1.0].min
          end

          def decayed?(confidence:, **)
            confidence < decay_threshold
          end

          def meets_write_gate?(confidence:, novelty:, **)
            confidence > write_confidence_gate && novelty > write_novelty_gate
          end
        end
      end
    end
  end
end
