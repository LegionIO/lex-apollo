# frozen_string_literal: true

require_relative '../helpers/confidence'
require_relative '../helpers/similarity'

module Legion
  module Extensions
    module Apollo
      module Runners
        module Maintenance
          def force_decay(factor: Helpers::Confidence.apollo_setting(:maintenance, :force_decay_factor, default: 0.5), **)
            { action: :force_decay, factor: factor }
          end

          def archive_stale(days: Helpers::Confidence.stale_days, **)
            { action: :archive_stale, days: days }
          end

          def resolve_dispute(entry_id:, resolution:, **)
            { action: :resolve_dispute, entry_id: entry_id, resolution: resolution }
          end

          def run_decay_cycle(alpha: nil, min_confidence: nil, **)
            alpha ||= Helpers::Confidence.power_law_alpha
            min_confidence ||= Helpers::Confidence.decay_threshold

            return { decayed: 0, archived: 0 } unless defined?(Legion::Data) && Legion::Data.respond_to?(:connection) && Legion::Data.connection

            conn = Legion::Data.connection

            hours_expr = Sequel.lit(
              'GREATEST(EXTRACT(EPOCH FROM (NOW() - COALESCE(updated_at, created_at))) / 3600.0, 1.0)'
            )
            decay_factor = Sequel.lit(
              'POWER(CAST(? AS double precision) / (CAST(? AS double precision) + 1.0), ?)', hours_expr, hours_expr, alpha
            )

            decayed = conn[:apollo_entries]
                      .exclude(status: 'archived')
                      .update(confidence: Sequel[:confidence] * decay_factor)

            archived = conn[:apollo_entries]
                       .where { confidence < min_confidence }
                       .exclude(status: 'archived')
                       .update(status: 'archived')

            { decayed: decayed, archived: archived, alpha: alpha, threshold: min_confidence }
          rescue Sequel::Error => e
            { decayed: 0, archived: 0, error: e.message }
          end

          def check_corroboration(**) # rubocop:disable Metrics/CyclomaticComplexity
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

              candidate_provider = candidate.respond_to?(:source_provider) ? candidate.source_provider : nil
              match_provider     = match.respond_to?(:source_provider) ? match.source_provider : nil
              both_known = known_provider?(candidate_provider) && known_provider?(match_provider)
              next if both_known && candidate_provider == match_provider

              candidate_channel = candidate.respond_to?(:source_channel) ? candidate.source_channel : nil
              match_channel = match.respond_to?(:source_channel) ? match.source_channel : nil
              next if candidate_channel && match_channel && candidate_channel == match_channel

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
                weight:        Helpers::Confidence.apollo_setting(:corroboration, :relation_weight, default: 1.0)
              )

              promoted += 1
            end

            { success: true, promoted: promoted, scanned: candidates.size }
          rescue Sequel::Error => e
            { success: false, error: e.message }
          end

          private

          def known_provider?(provider)
            !provider.nil? && !provider.to_s.empty? && provider.to_s != 'unknown'
          end

          include Legion::Extensions::Helpers::Lex if defined?(Legion::Extensions::Helpers::Lex)
        end
      end
    end
  end
end
