# frozen_string_literal: true

require 'legion/json'
require_relative '../helpers/confidence'
require_relative '../helpers/data_models'
require_relative '../helpers/similarity'
require_relative '../helpers/graph_query'

module Legion
  module Extensions
    module Apollo
      module Runners
        module Maintenance
          def force_decay(factor: Legion::Extensions::Apollo.settings[:maintenance][:force_decay_factor], **)
            return { action: :force_decay, factor: factor } unless Legion::Extensions::Apollo::Helpers::DataModels.apollo_entry_available?
            return { success: false, error: 'invalid_factor' } unless factor.is_a?(Numeric) && factor.real? && factor.finite? && factor.between?(0.0, 1.0)

            decayed = Legion::Extensions::Apollo::Helpers::DataModels.apollo_entry
                                                                     .exclude(status: 'archived')
                                                                     .update(confidence: Sequel[:confidence] * factor)
            { success: true, decayed: decayed, factor: factor }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.maintenance.force_decay')
            { success: false, decayed: 0, error: e.message }
          end

          def archive_stale(days: Helpers::Confidence.stale_days, **)
            return { action: :archive_stale, days: days } unless Legion::Extensions::Apollo::Helpers::DataModels.apollo_entry_available?
            return { success: false, error: 'invalid_days' } unless days.is_a?(Numeric) && days.real? && days.finite? && days >= 0

            now = Time.now
            cutoff = now - (days * 86_400)
            archived = Legion::Extensions::Apollo::Helpers::DataModels.apollo_entry
                                                                      .exclude(status: 'archived')
                                                                      .where(Sequel.function(:coalesce, :updated_at, :created_at) < cutoff)
                                                                      .update(status: 'archived', updated_at: now)
            { success: true, archived: archived, days: days }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.maintenance.archive_stale')
            { success: false, archived: 0, error: e.message }
          end

          def resolve_dispute(entry_id:, resolution:, **)
            unless Legion::Extensions::Apollo::Helpers::DataModels.apollo_entry_available?
              return { action: :resolve_dispute, entry_id: entry_id, resolution: resolution }
            end

            target_status = case resolution.to_s
                            when 'accept', 'keep' then 'confirmed'
                            when 'reject' then 'archived'
                            end
            return { success: false, error: 'invalid_resolution', entry_id: entry_id } unless target_status

            entry_model = Legion::Extensions::Apollo::Helpers::DataModels.apollo_entry
            entry_model.db.transaction do
              entry = entry_model.for_update.with_pk(entry_id)
              next({ success: false, error: 'entry_not_found', entry_id: entry_id }) unless entry
              next({ success: false, error: 'entry_not_disputed', entry_id: entry.id, status: entry.status }) unless entry.status == 'disputed'

              context = entry[:source_context]
              context = Legion::JSON.load(context) if context.is_a?(String)
              context ||= {}
              raise Sequel::Error, 'invalid_source_context' unless context.respond_to?(:transform_keys)

              context = context.transform_keys(&:to_sym)
              now = Time.now
              updates = { status: target_status, updated_at: now,
                          source_context: Legion::JSON.dump(context.merge(dispute_resolution: resolution.to_s)) }
              updates[:confirmed_at] = now if target_status == 'confirmed'
              entry.update(updates)
              { success: true, entry_id: entry.id, status: target_status, resolution: resolution }
            end
          rescue Sequel::Error, Legion::JSON::ParseError => e
            handle_exception(e, level: :error, operation: 'apollo.maintenance.resolve_dispute')
            { success: false, error: e.message, entry_id: entry_id }
          end

          def run_decay_cycle(alpha: nil, min_confidence: nil, **)
            alpha ||= Helpers::Confidence.power_law_alpha
            min_confidence ||= Helpers::Confidence.decay_threshold
            min_age_hours = Helpers::Confidence.decay_min_age_hours

            log.debug("Apollo Maintenance.run_decay_cycle alpha=#{alpha} min_confidence=#{min_confidence} min_age_hours=#{min_age_hours}")
            unless defined?(Legion::Data) && Legion::Data.respond_to?(:connection) && Legion::Data.connection
              log.warn('Apollo Maintenance.run_decay_cycle skipped: apollo_data_not_available')
              return { decayed: 0, archived: 0 }
            end

            conn = Legion::Data.connection

            age_days_expr = Sequel.lit(
              'GREATEST(EXTRACT(EPOCH FROM (NOW() - COALESCE(updated_at, created_at))) / 86400.0, 1.0)'
            )
            decay_factor = Sequel.lit(
              'POWER(CAST(? AS double precision) / (CAST(? AS double precision) + 1.0), ?)',
              age_days_expr, age_days_expr, alpha
            )

            min_age_filter = Sequel.lit(
              "COALESCE(updated_at, created_at) < NOW() - (? * INTERVAL '1 hour')",
              min_age_hours
            )

            decayed = conn[:apollo_entries]
                      .exclude(status: 'archived')
                      .where(min_age_filter)
                      .update(confidence: Sequel[:confidence] * decay_factor)

            archived = conn[:apollo_entries]
                       .where { confidence < min_confidence }
                       .where(min_age_filter)
                       .exclude(status: 'archived')
                       .update(status: 'archived')

            { decayed: decayed, archived: archived, alpha: alpha, threshold: min_confidence,
              min_age_hours: min_age_hours }
              .tap { |result| log.info("Apollo Maintenance.run_decay_cycle decayed=#{result[:decayed]} archived=#{result[:archived]} alpha=#{alpha} threshold=#{min_confidence}") } # rubocop:disable Layout/LineLength
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.maintenance.run_decay_cycle')
            { decayed: 0, archived: 0, error: e.message }
          end

          def check_corroboration(**)
            unless Helpers::DataModels.apollo_entry_available? && Helpers::DataModels.apollo_relation_available?
              missing = []
              missing << 'entry' unless Helpers::DataModels.apollo_entry_available?
              missing << 'relation' unless Helpers::DataModels.apollo_relation_available?
              log.warn("Apollo Maintenance.check_corroboration skipped: apollo_data_not_available missing=#{missing.join(',')}")
              return { success: false, error: 'apollo_data_not_available' }
            end

            entry_model = Helpers::DataModels.apollo_entry
            candidates = entry_model.where(status: 'candidate').exclude(embedding: nil).order(:id).limit(100).all
            confirmed_ids = entry_model.where(status: 'confirmed').select_map(:id)
            log.debug("Apollo Maintenance.check_corroboration candidates=#{candidates.size} confirmed=#{confirmed_ids.size}")

            promoted = 0
            candidates.each_with_index do |candidate, index|
              match = corroboration_match_for(candidate: candidate, evidence_ids: confirmed_ids) ||
                      bootstrap_match_for(candidate: candidate, candidates: candidates, candidate_index: index)
              next unless match

              bootstrap = !confirmed_ids.include?(match.id)
              updates = {
                status:       'confirmed',
                confirmed_at: Time.now,
                confidence:   Helpers::Confidence.apply_corroboration_boost(confidence: candidate.confidence),
                updated_at:   Time.now
              }
              updates[:source_context] = bootstrap_confirmation_context(candidate) if bootstrap
              candidate.update(updates)
              Helpers::DataModels.apollo_relation.create(
                from_entry_id: candidate.id,
                to_entry_id:   match.id,
                relation_type: 'similar_to',
                source_agent:  'system:corroboration',
                weight:        Legion::Extensions::Apollo.settings[:corroboration][:relation_weight]
              )
              promoted += 1
            end

            { success: true, promoted: promoted, scanned: candidates.size }
              .tap { |result| log.info("Apollo Maintenance.check_corroboration scanned=#{result[:scanned]} promoted=#{result[:promoted]}") }
          rescue Sequel::Error, Legion::JSON::ParseError => e
            handle_exception(e, level: :error, operation: 'apollo.maintenance.check_corroboration')
            { success: false, error: e.message }
          end

          private

          def corroboration_match_for(candidate:, evidence_ids:)
            return nil if evidence_ids.empty?

            scope = candidate.access_scope || 'global'
            return nil if scope != 'global' && candidate.identity_principal_id.nil?

            evidence = Helpers::DataModels.apollo_entry
                                          .where(id: evidence_ids, content_type: candidate.content_type,
                                                 knowledge_domain: candidate.knowledge_domain, access_scope: scope)
                                          .exclude(embedding: nil)
            if scope != 'global'
              evidence = evidence.where(
                Sequel.lit(Legion::Extensions::Apollo::Helpers::GraphQuery.access_scope_sql,
                           requesting_principal_id: candidate.identity_principal_id)
              )
            end

            evidence.limit(500).find { |entry| corroborates?(candidate: candidate, entry: entry) }
          end

          def bootstrap_match_for(candidate:, candidates:, candidate_index:)
            evidence_ids = candidates.drop(candidate_index + 1).map(&:id)
            corroboration_match_for(candidate: candidate, evidence_ids: evidence_ids)
          end

          def corroborates?(candidate:, entry:)
            return false if candidate.id == entry.id
            return false if bootstrap_confirmation?(entry)

            both_known = known_provider?(candidate.source_provider) && known_provider?(entry.source_provider)
            return false if both_known && candidate.source_provider == entry.source_provider
            return false if candidate.source_channel && candidate.source_channel == entry.source_channel

            similarity = Helpers::Similarity.cosine_similarity(vec_a: candidate.embedding, vec_b: entry.embedding)
            Helpers::Similarity.above_corroboration_threshold?(similarity: similarity)
          end

          def bootstrap_confirmation_context(entry)
            context = entry[:source_context]
            context = Legion::JSON.load(context) if context.is_a?(String)
            context ||= {}
            raise Sequel::Error, 'invalid_source_context' unless context.respond_to?(:transform_keys)

            Legion::JSON.dump(context.transform_keys(&:to_sym).merge(corroboration_mode: 'bootstrap'))
          end

          def bootstrap_confirmation?(entry)
            return false unless entry.status == 'confirmed'

            context = entry[:source_context]
            context = Legion::JSON.load(context) if context.is_a?(String)
            context.respond_to?(:[]) && (context[:corroboration_mode] || context['corroboration_mode']) == 'bootstrap'
          rescue Legion::JSON::ParseError => e
            handle_exception(e, level: :warn, operation: 'apollo.maintenance.bootstrap_confirmation')
            true
          end

          def known_provider?(provider)
            !provider.nil? && !provider.to_s.empty? && provider.to_s != 'unknown'
          end

          include Legion::Extensions::Helpers::Lex if defined?(Legion::Extensions::Helpers::Lex)
        end
      end
    end
  end
end
