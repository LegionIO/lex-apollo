# frozen_string_literal: true

require_relative '../helpers/confidence'
require_relative '../helpers/similarity'
require_relative '../helpers/embedding'

module Legion
  module Extensions
    module Apollo
      module Runners
        module Maintenance
          def force_decay(factor: 0.5, **)
            { action: :force_decay, factor: factor }
          end

          def archive_stale(days: 90, **)
            { action: :archive_stale, days: days }
          end

          def resolve_dispute(entry_id:, resolution:, **)
            { action: :resolve_dispute, entry_id: entry_id, resolution: resolution }
          end

          def run_decay_cycle(rate: nil, min_confidence: nil, **)
            rate ||= decay_rate
            min_confidence ||= decay_threshold

            return { decayed: 0, archived: 0 } unless defined?(Legion::Data) && Legion::Data.respond_to?(:connection) && Legion::Data.connection

            conn = Legion::Data.connection
            decayed = conn[:apollo_entries]
                      .exclude(status: 'archived')
                      .update(confidence: Sequel[:confidence] * rate)

            archived = conn[:apollo_entries]
                       .where { confidence < min_confidence }
                       .exclude(status: 'archived')
                       .update(status: 'archived')

            { decayed: decayed, archived: archived, rate: rate, threshold: min_confidence }
          rescue Sequel::Error => e
            { decayed: 0, archived: 0, error: e.message }
          end

          def check_corroboration(**)
            return { success: false, error: 'apollo_data_not_available' } unless defined?(Legion::Data::Model::ApolloEntry)

            candidates = Legion::Data::Model::ApolloEntry.where(status: 'candidate').exclude(embedding: nil).all
            confirmed = Legion::Data::Model::ApolloEntry.where(status: 'confirmed').exclude(embedding: nil).all

            promoted = 0

            candidates.each do |candidate|
              match = confirmed.find do |conf|
                next unless conf.content_type == candidate.content_type

                sim = Helpers::Similarity.cosine_similarity(
                  vec_a: candidate.embedding, vec_b: conf.embedding
                )
                Helpers::Similarity.above_corroboration_threshold?(similarity: sim)
              end

              next unless match

              candidate.update(
                status:       'confirmed',
                confirmed_at: Time.now,
                confidence:   Helpers::Confidence.apply_corroboration_boost(confidence: candidate.confidence),
                updated_at:   Time.now
              )

              Legion::Data::Model::ApolloRelation.create(
                from_entry_id: candidate.id,
                to_entry_id:   match.id,
                relation_type: 'similar_to',
                source_agent:  'system:corroboration',
                weight:        1.0
              )

              promoted += 1
            end

            { success: true, promoted: promoted, scanned: candidates.size }
          rescue Sequel::Error => e
            { success: false, error: e.message }
          end

          private

          def decay_rate
            (defined?(Legion::Settings) && Legion::Settings.dig(:apollo, :decay_rate)) || 0.998
          end

          def decay_threshold
            (defined?(Legion::Settings) && Legion::Settings.dig(:apollo, :decay_threshold)) || 0.1
          end

          include Legion::Extensions::Helpers::Lex if defined?(Legion::Extensions::Helpers::Lex)
        end
      end
    end
  end
end
