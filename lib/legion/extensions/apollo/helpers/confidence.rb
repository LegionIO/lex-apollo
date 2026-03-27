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

          def apollo_setting(*keys, default:)
            return default unless defined?(Legion::Settings) && !Legion::Settings[:apollo].nil?

            Legion::Settings[:apollo].dig(*keys) || default
          rescue StandardError => e
            Legion::Logging.warn("Apollo Confidence.apollo_setting failed: #{e.message}") if defined?(Legion::Logging)
            default
          end

          def initial_confidence     = apollo_setting(:confidence, :initial, default: INITIAL_CONFIDENCE)
          def corroboration_boost    = apollo_setting(:confidence, :corroboration_boost, default: CORROBORATION_BOOST)
          def retrieval_boost        = apollo_setting(:confidence, :retrieval_boost, default: RETRIEVAL_BOOST)
          def power_law_alpha        = apollo_setting(:power_law_alpha, default: POWER_LAW_ALPHA)
          def decay_threshold        = apollo_setting(:decay_threshold, default: DECAY_THRESHOLD)
          def write_confidence_gate  = apollo_setting(:confidence, :write_gate, default: WRITE_CONFIDENCE_GATE)
          def write_novelty_gate     = apollo_setting(:confidence, :novelty_gate, default: WRITE_NOVELTY_GATE)
          def stale_days             = apollo_setting(:stale_days, default: STALE_DAYS)

          def corroboration_similarity_threshold
            apollo_setting(:confidence, :corroboration_similarity, default: CORROBORATION_SIMILARITY_THRESHOLD)
          end

          def apply_decay(confidence:, age_hours: nil, alpha: power_law_alpha, **)
            if age_hours
              [confidence * ((age_hours.clamp(0, Float::INFINITY) + 2.0)**(-alpha)) / ((age_hours.clamp(0, Float::INFINITY) + 1.0)**(-alpha)), 0.0].max
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
