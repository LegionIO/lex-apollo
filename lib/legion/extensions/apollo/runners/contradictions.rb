# frozen_string_literal: true

require 'legion/llm'
require 'legion/logging/helper'
require 'legion/settings/helper'
require 'legion/extensions/apollo/helpers/data_models'
require 'legion/extensions/apollo/helpers/embedding'
require 'legion/extensions/apollo/helpers/similarity'
require 'legion/extensions/apollo/helpers/storage'
require 'legion/extensions/apollo/runners/search'

module Legion
  module Extensions
    module Apollo
      module Runners
        module Contradictions
          include Legion::Logging::Helper
          include Legion::Settings::Helper
          extend Legion::Extensions::Apollo::Helpers::DataModels
          extend Legion::Extensions::Apollo::Helpers::Embedding
          extend Legion::Extensions::Apollo::Helpers::Similarity
          extend self

          PENDING_ENTRIES = Queue.new
          QUEUE_MUTEX     = Mutex.new
          private_constant :PENDING_ENTRIES, :QUEUE_MUTEX

          def enqueue(entry_id:, **)
            QUEUE_MUTEX.synchronize { PENDING_ENTRIES << { entry_id: entry_id } }
            { success: true, queued: true, entry_id: entry_id, pending: PENDING_ENTRIES.size }
          end

          def scan_pending_contradictions(**)
            items = QUEUE_MUTEX.synchronize do
              Array.new(PENDING_ENTRIES.size) { PENDING_ENTRIES.pop(true) }
            end
            return { success: true, processed: 0, failed: 0 } if items.empty?

            processed = 0
            failed = 0
            items.each do |item|
              contradictions_detect(entry_id: item[:entry_id])
              processed += 1
            rescue StandardError => e
              QUEUE_MUTEX.synchronize { PENDING_ENTRIES << item }
              failed += 1
              handle_exception(e, level: :error, operation: 'apollo.contradictions.scan', entry_id: item[:entry_id])
            end
            log.info("Apollo Contradictions.scan_pending_contradictions processed=#{processed} failed=#{failed}")
            { success: failed.zero?, processed: processed, failed: failed }
          end

          private

          def contradictions_detect(entry_id:, **)
            raise 'Apollo data is unavailable for contradiction scanning' if data_model_entry.nil?

            entry_model = data_model_entry
            entry = entry_model[entry_id]
            return { success: true, contradictions: [] } unless entry && entry.status != 'archived'

            provenance = embedding_parse_provenance(value: entry[:embedding_provenance])
            embedding = similarity_parse_vector(vector: entry[:embedding])
            return { success: true, contradictions: [] } unless embedding_valid?(vector: embedding, provenance: provenance, task: :document)
            return { success: true, contradictions: [] } if entry.access_scope != 'global' && !entry.identity_principal_id.to_i.positive?

            similar = Legion::Extensions::Apollo::Runners::Search.semantic_search(
              db: entry_model.db, embedding: embedding, provenance: provenance,
              limit: settings[:contradiction][:similar_limit] + 1,
              min_confidence: 0.0, statuses: %w[candidate confirmed], domain: entry.knowledge_domain,
              access_scope: entry.access_scope, identity_principal_id: entry.identity_principal_id
            ).fetch(:entries)
            contradictions = similar.filter_map do |existing|
              next if existing[:id] == entry_id
              next unless 1.0 - existing[:distance] > settings[:contradiction][:similarity_threshold]
              next unless contradictions_llm_conflict?(content_a: entry.content, content_b: existing[:content])

              existing[:id]
            end
            contradictions_write(entry_id: entry_id, contradictions: contradictions, db: entry_model.db)
            log.info("Apollo Contradictions.detect entry_id=#{entry_id} contradictions=#{contradictions.size}") if contradictions.any?
            { success: true, contradictions: contradictions }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.contradictions.detect', entry_id: entry_id)
            raise
          end

          def contradictions_write(entry_id:, contradictions:, db:, **)
            return if contradictions.empty?

            db.transaction do
              contradictions.each do |contradicted_id|
                data_model_relation.create(
                  from_entry_id: entry_id, to_entry_id: contradicted_id,
                  relation_type: 'contradicts', source_agent: 'system:contradiction',
                  weight: settings[:contradiction][:relation_weight]
                )
              end
              data_model_entry
                .where(id: [entry_id, *contradictions]).update(status: 'disputed')
            end
          end

          def contradictions_llm_conflict?(content_a:, content_b:, **)
            raise 'LLM is unavailable for contradiction scanning' unless Legion::LLM.started?

            max_chars = settings[:contradiction][:max_content_chars]

            result = Legion::LLM.structured(
              messages: [
                { role: 'system', content: 'Do these two statements contradict each other? Return JSON.' },
                { role: 'user', content: "A: #{content_a.to_s[0, max_chars]}\n\nB: #{content_b.to_s[0, max_chars]}" }
              ],
              schema:   { type: 'object', properties: { contradicts: { type: 'boolean' } } },
              caller:   { extension: 'lex-apollo', runner: 'contradictions' }
            )
            contradicts = result.dig(:data, :contradicts)
            raise 'Contradiction classification did not return a boolean' unless [true, false].include?(contradicts)

            contradicts
          end
        end
      end
    end
  end
end
