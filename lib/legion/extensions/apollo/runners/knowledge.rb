# frozen_string_literal: true

require 'legion/json'
require 'legion/settings'
require 'legion/logging/helper'
require 'legion/extensions/apollo/helpers/confidence'
require 'legion/extensions/apollo/helpers/data_models'
require 'legion/extensions/apollo/helpers/embedding'
require 'legion/extensions/apollo/helpers/storage'
require 'legion/extensions/apollo/helpers/tag_normalizer'
require 'legion/extensions/apollo/runners/contradictions'
require 'legion/extensions/apollo/runners/embedding'
require 'legion/extensions/apollo/runners/search'
module Legion
  module Extensions
    module Apollo
      module Runners
        module Knowledge
          include Legion::Logging::Helper
          include Legion::JSON::Helper
          include Legion::Settings::Helper
          extend Legion::Extensions::Apollo::Helpers::DataModels
          extend Legion::Extensions::Apollo::Helpers::Confidence
          extend Legion::Extensions::Apollo::Helpers::TagNormalizer
          extend Legion::Extensions::Apollo::Helpers::Storage
          extend Legion::Extensions::Apollo::Helpers::Embedding
          extend Legion::Extensions::Apollo::Helpers::Similarity
          extend Legion::Extensions::Apollo::Helpers::GraphQuery
          extend self

          CONTENT_TYPE_ALIASES = {
            reasoning: :concept, analysis: :concept, explanation: :concept,
            text: :observation, general: :observation, note: :observation, summary: :observation,
            rule: :procedure, step: :procedure, instruction: :procedure,
            link: :association, relation: :association, connection: :association,
            inference: :association, implication: :association
          }.freeze
          DEFAULT_QUERY_STATUS = [:confirmed].freeze
          UNSET = Object.new.freeze

          def store_knowledge(content:, content_type:, tags: [], source_agent: nil, context: {}, **)
            content_type = knowledge_normalize_content_type(content_type)
            log.debug("Apollo Knowledge.store_knowledge content_type=#{content_type} tags=#{Array(tags).size} source_agent=#{source_agent || 'nil'} data_available=#{!data_model_entry.nil?}") # rubocop:disable Layout/LineLength

            unless data_model_entry.nil?
              return handle_ingest(content: content, content_type: content_type,
                                   tags: Array(tags), source_agent: source_agent, context: context, **)
            end

            {
              action:       :store,
              content:      content,
              content_type: content_type,
              tags:         Array(tags),
              source_agent: source_agent,
              context:      context
            }
          end

          def query_knowledge(query:, limit: settings[:query][:default_limit], min_confidence: settings[:query][:default_min_confidence], status: %i[confirmed candidate], tags: nil, **) # rubocop:disable Layout/LineLength
            log.debug("Apollo Knowledge.query_knowledge query_length=#{query.to_s.length} limit=#{limit} statuses=#{Array(status).join(',')} tags=#{Array(tags).size} data_available=#{!data_model_entry.nil?}") # rubocop:disable Layout/LineLength
            unless data_model_entry.nil?
              return handle_query(query: query, limit: limit, min_confidence: min_confidence,
                                  status: status, tags: tags, **)
            end

            {
              action:         :query,
              query:          query,
              limit:          limit,
              min_confidence: min_confidence,
              status:         Array(status),
              tags:           tags
            }
          end

          def related_entries(entry_id:, relation_types: nil, depth: settings[:graph][:default_depth], **)
            log.debug("Apollo Knowledge.related_entries entry_id=#{entry_id} depth=#{depth} relation_types=#{Array(relation_types).join(',')} data_available=#{!data_model_entry.nil?}") # rubocop:disable Layout/LineLength
            return handle_traverse(entry_id: entry_id, depth: depth, relation_types: relation_types, **) unless data_model_entry.nil?

            {
              action:         :traverse,
              entry_id:       entry_id,
              relation_types: relation_types,
              depth:          depth
            }
          end

          def deprecate_entry(entry_id:, reason:, requesting_principal_id: nil, **)
            return { action: :deprecate, entry_id: entry_id, reason: reason } if data_model_entry.nil?

            entry_model = data_model_entry
            requesting_principal_id = knowledge_resolve_requesting_principal_id(requesting_principal_id)
            entry_model.db.transaction do
              entries = entry_model.for_update
              if requesting_principal_id
                entries = entries.where(Sequel.lit(graph_access_scope_sql(global_only: requesting_principal_id.zero?),
                                                   requesting_principal_id: requesting_principal_id))
              end
              entry = entries.with_pk(entry_id)
              next({ success: false, error: 'entry_not_found', entry_id: entry_id }) unless entry

              context = entry[:source_context]
              context = Legion::JSON.load(context) if context.is_a?(String)
              context ||= {}
              raise Sequel::Error, 'invalid_source_context' unless context.respond_to?(:transform_keys)

              context = context.transform_keys(&:to_sym)
              unchanged = entry.status == 'archived' && context[:deprecation_reason] == reason
              unless unchanged
                entry.update(status: 'archived', source_context: Legion::JSON.dump(context.merge(deprecation_reason: reason)),
                             updated_at: Time.now)
              end
              { success: true, entry_id: entry.id, status: 'archived', updated: !unchanged, reason: reason }
            end
          rescue Sequel::Error, Legion::JSON::ParseError => e
            handle_exception(e, level: :error, operation: 'apollo.knowledge.deprecate_entry')
            { success: false, error: e.message, entry_id: entry_id }
          end

          def handle_ingest(content:, content_type: :observation, tags: [], source_agent: 'unknown', # rubocop:disable Metrics/ParameterLists
                            source_provider: nil, source_model: nil, source_channel: nil, knowledge_domain: nil,
                            submitted_by: nil, submitted_from: nil, content_hash: nil, context: {},
                            skip: false, access_scope: 'global', embedding: nil, embedding_provenance: nil,
                            identity_principal_id: UNSET, identity_id: UNSET, identity_canonical_name: UNSET, **)
            return { status: :skipped } if skip

            identity = knowledge_resolve_process_identity(principal_id: identity_principal_id, identity_id: identity_id,
                                                          canonical_name: identity_canonical_name)
            access_scope = (access_scope || 'global').to_s
            return { success: false, error: 'invalid_access_scope' } unless %w[global private team].include?(access_scope)
            if access_scope != 'global' && !(identity[:principal_id].is_a?(Integer) && identity[:principal_id].positive?)
              return { success: false, error: 'identity_required' }
            end

            content = knowledge_normalize_text_input(content)
            content_type = knowledge_normalize_content_type(content_type.nil? ? :observation : content_type)
            log.debug("Apollo Knowledge.handle_ingest content_length=#{content.length} content_type=#{content_type} tags=#{Array(tags).size} source_agent=#{source_agent} source_channel=#{source_channel || 'nil'}") # rubocop:disable Layout/LineLength
            early_error = knowledge_ingest_early_return_error(content: content, content_type: content_type, tags: tags)
            return early_error if early_error

            hash = content_hash || Legion::Extensions::Apollo::Helpers::Writeback.content_hash(content: content)
            existing = knowledge_active_duplicate_for_hash(content_hash: hash, access_scope: access_scope,
                                                           identity_principal_id: identity[:principal_id])
            if existing
              knowledge_refresh_duplicate_embedding(entry: existing)
              log.info("Apollo Knowledge.handle_ingest deduped entry_id=#{existing.id} source_agent=#{source_agent}")
              return { success: true, entry_id: existing.id, deduped: true }
            end

            document = Legion::Extensions::Apollo::Runners::Embedding.document(
              text: content, vector: embedding, provenance: embedding_provenance
            )
            metadata = knowledge_ingest_metadata(tags: tags, knowledge_domain: knowledge_domain, source_agent: source_agent,
                                                 source_provider: source_provider, source_channel: source_channel,
                                                 submitted_by: submitted_by, submitted_from: submitted_from,
                                                 access_scope: access_scope,
                                                 identity_principal_id: identity[:principal_id],
                                                 identity_id: identity[:identity_id],
                                                 identity_canonical_name: identity[:canonical_name])

            context = (context.is_a?(Hash) ? context : {}).merge(source_model: source_model) unless source_model.nil?
            result = knowledge_persist_ingest(content: content, content_type: content_type.to_s, context: context,
                                              metadata: metadata, content_hash: hash,
                                              embedding: document[:vector], provenance: document[:provenance])
            knowledge_schedule_contradiction_detection(entry_id: result[:entry_id])
            log.debug("Apollo Knowledge.handle_ingest complete entry_id=#{result[:entry_id]} corroborated=#{result[:corroborated]}")
            result
          rescue Sequel::Error, Legion::LLM::LLMError, Legion::Extensions::Apollo::Helpers::Embedding::Error => e
            handle_exception(e, level: :error, operation: 'apollo.knowledge.handle_ingest')
            { success: false, error: e.message }
          end

          def handle_query(query:, limit: settings[:query][:default_limit], # rubocop:disable Metrics/ParameterLists
                           min_confidence: settings[:query][:default_min_confidence],
                           status: UNSET, tags: nil, tag_match: :any, exclude_source_agents: [], domain: nil, agent_id: 'unknown',
                           requesting_principal_id: nil, **)
            return { success: false, error: 'apollo_data_not_available' } if data_model_entry.nil?
            return { success: false, error: 'invalid_tag_match' } unless %w[any all].include?(tag_match.to_s)

            requesting_principal_id = knowledge_resolve_requesting_principal_id(requesting_principal_id)
            entry_model = data_model_entry
            query = knowledge_normalize_text_input(query)
            status_defaulted = status.equal?(UNSET)
            requested_status = status_defaulted ? DEFAULT_QUERY_STATUS : status
            log.debug("Apollo Knowledge.handle_query query_length=#{query.length} limit=#{limit} statuses=#{requested_status.inspect} status_defaulted=#{status_defaulted} domain=#{domain.inspect} agent_id=#{agent_id}") # rubocop:disable Layout/LineLength
            if knowledge_browse_query?(query)
              return knowledge_list_entries_chronologically(query: query, limit: limit, status: requested_status,
                                                            status_defaulted: status_defaulted, tags: tags, domain: domain,
                                                            requesting_principal_id: requesting_principal_id, min_confidence: min_confidence,
                                                            tag_match: tag_match, exclude_source_agents: exclude_source_agents)
            end

            if data_model_access_log.nil?
              log.warn('Apollo Knowledge.handle_query skipped: apollo_data_not_available missing=access_log')
              return { success: false, error: 'apollo_data_not_available' }
            end

            embedding = Legion::Extensions::Apollo::Runners::Embedding.generate(text: query, task: :query)

            query_options = {
              limit: limit, min_confidence: min_confidence,
              statuses: Array(requested_status).map(&:to_s), tags: Array(tags).map(&:to_s),
              tag_match: tag_match, exclude_source_agents: Array(exclude_source_agents).map(&:to_s),
              domain: domain&.to_s, requesting_principal_id: requesting_principal_id&.to_i
            }
            entries = Legion::Extensions::Apollo::Runners::Search.semantic_search(
              db: entry_model.db, embedding: embedding[:vector], provenance: embedding[:provenance], **query_options
            ).fetch(:entries)

            entries.each do |entry|
              knowledge_boost_entry_after_query(entry_model, entry)
            end

            knowledge_record_query_access(entry_id: entries.first[:id], agent_id: agent_id) if entries.any?

            formatted = entries.map { |entry| knowledge_format_entry(entry: entry) }

            log.info("Apollo Knowledge.handle_query results=#{formatted.size} mode=semantic agent_id=#{agent_id}")
            { success: true, entries: formatted, count: formatted.size }
          rescue Sequel::Error, Legion::JSON::ParseError, Legion::LLM::LLMError, Legion::Extensions::Apollo::Helpers::Embedding::Error => e
            handle_exception(e, level: :error, operation: 'apollo.knowledge.handle_query')
            { success: false, error: e.message }
          end

          def handle_traverse(entry_id:, depth: settings[:graph][:default_depth], relation_types: nil,
                              agent_id: 'unknown', requesting_principal_id: nil, **)
            return { success: false, error: 'apollo_data_not_available' } if data_model_entry.nil?

            if agent_id != 'unknown' && data_model_access_log.nil?
              log.warn('Apollo Knowledge.handle_traverse skipped: apollo_data_not_available missing=access_log')
              return { success: false, error: 'apollo_data_not_available' }
            end

            log.debug("Apollo Knowledge.handle_traverse entry_id=#{entry_id} depth=#{depth} relation_types=#{Array(relation_types).join(',')} agent_id=#{agent_id}") # rubocop:disable Layout/LineLength
            # Keep traversal limited to the supported relation vocabulary.
            if relation_types
              allowed = Legion::Extensions::Apollo::Helpers::Confidence::RELATION_TYPES
              relation_types = relation_types.map(&:to_s).select { |type| allowed.include?(type) }
            end

            requesting_principal_id = knowledge_resolve_requesting_principal_id(requesting_principal_id)
            sql = graph_build_traversal_sql(depth: depth, relation_types: relation_types,
                                            requesting_principal_id: requesting_principal_id)
            db = data_model_entry.db
            entries = db.fetch(sql, entry_id: entry_id, depth: depth, relation_types: relation_types,
                                   requesting_principal_id: requesting_principal_id,
                                   spread_factor: settings[:graph][:spread_factor],
                                   min_activation: settings[:graph][:min_activation]).all

            if entries.any? && agent_id != 'unknown'
              data_model_access_log.create(
                entry_id: entry_id, agent_id: agent_id, action: 'query'
              )
            end

            formatted = entries.map do |entry|
              { id: entry[:id], content: entry[:content], content_type: entry[:content_type],
                confidence: entry[:confidence], tags: storage_deserialize_tags(tags: entry[:tags]),
                source_agent: entry[:source_agent],
                depth: entry[:depth], activation: entry[:activation] }
            end

            log.info("Apollo Knowledge.handle_traverse results=#{formatted.size} entry_id=#{entry_id}")
            { success: true, entries: formatted, count: formatted.size }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.knowledge.handle_traverse')
            { success: false, error: e.message }
          end

          def redistribute_knowledge(agent_id:, min_confidence: settings[:query][:redistribute_min_confidence], **)
            return { success: false, error: 'apollo_data_not_available' } if data_model_entry.nil?

            log.debug("Apollo Knowledge.redistribute_knowledge agent_id=#{agent_id} min_confidence=#{min_confidence}")
            entries = data_model_entry
                      .where(source_agent: agent_id, status: 'confirmed')
                      .where { confidence > min_confidence }
                      .all

            return { success: true, redistributed: 0 } if entries.empty?

            store = (Legion::Extensions::Agentic::Memory::Trace.shared_store if defined?(Legion::Extensions::Agentic::Memory::Trace))
            return { success: false, error: 'memory_trace_not_available', redistributed: 0 } unless store

            redistributed = 0
            entries.each do |entry|
              if store
                tags = storage_deserialize_tags(tags: entry.tags)
                trace = Legion::Extensions::Agentic::Memory::Trace::Helpers::Trace.new_trace(
                  type:            :semantic,
                  content_payload: { content: entry.content, source_agent: agent_id,
                                     content_type: entry.content_type, tags: tags },
                  strength:        entry.confidence.to_f,
                  domain_tag:      tags.first || 'general'
                )
                store.store(trace)
              end
              redistributed += 1
            end

            log.info("[apollo] redistributed #{redistributed} entries from departing agent=#{agent_id}")
            { success: true, redistributed: redistributed, agent_id: agent_id }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.knowledge.redistribute_knowledge')
            { success: false, error: e.message }
          end

          def retrieve_relevant(query: nil, limit: settings[:query][:retrieval_limit], # rubocop:disable Metrics/ParameterLists
                                min_confidence: settings[:query][:default_min_confidence],
                                status: %i[confirmed candidate], tags: nil, tag_match: :any, exclude_source_agents: [], domain: nil,
                                skip: false, requesting_principal_id: nil, **)
            return { status: :skipped } if skip

            return { success: false, error: 'apollo_data_not_available' } if data_model_entry.nil?
            return { success: false, error: 'invalid_tag_match' } unless %w[any all].include?(tag_match.to_s)

            requesting_principal_id = knowledge_resolve_requesting_principal_id(requesting_principal_id)
            query = knowledge_normalize_text_input(query)
            log.debug("Apollo Knowledge.retrieve_relevant query_length=#{query.length} limit=#{limit} min_confidence=#{min_confidence} tags=#{Array(tags).size} domain=#{domain.inspect}") # rubocop:disable Layout/LineLength
            return { success: true, entries: [], count: 0 } if query.to_s.strip.empty?

            embedding = Legion::Extensions::Apollo::Runners::Embedding.generate(text: query, task: :query)

            query_options = {
              limit: limit, min_confidence: min_confidence,
              statuses: Array(status).map(&:to_s), tags: Array(tags).map(&:to_s),
              tag_match: tag_match, exclude_source_agents: Array(exclude_source_agents).map(&:to_s),
              domain: domain&.to_s, requesting_principal_id: requesting_principal_id&.to_i
            }
            entries = Legion::Extensions::Apollo::Runners::Search.semantic_search(
              db: data_model_entry.db,
              embedding: embedding[:vector], provenance: embedding[:provenance], **query_options
            ).fetch(:entries)

            entries.each do |entry|
              data_model_entry.where(id: entry[:id]).update(
                confidence: confidence_apply_retrieval_boost(confidence: entry[:confidence]),
                updated_at: Time.now
              )
            end

            formatted = entries.map { |entry| knowledge_format_entry(entry: entry) }

            log.info("Apollo Knowledge.retrieve_relevant results=#{formatted.size} limit=#{limit}")
            { success: true, entries: formatted, count: formatted.size }
          rescue Sequel::Error, Legion::JSON::ParseError, Legion::LLM::LLMError, Legion::Extensions::Apollo::Helpers::Embedding::Error => e
            handle_exception(e, level: :error, operation: 'apollo.knowledge.retrieve_relevant')
            { success: false, error: e.message }
          end

          def prepare_mesh_export(target_domain:, min_confidence: settings[:query][:mesh_export_min_confidence], limit: settings[:query][:mesh_export_limit], **) # rubocop:disable Layout/LineLength
            return { success: false, error: 'apollo_data_not_available' } unless Legion::Data.connection

            log.debug("Apollo Knowledge.prepare_mesh_export target_domain=#{target_domain} min_confidence=#{min_confidence} limit=#{limit}")
            conn = Legion::Data.connection
            allowed = knowledge_allowed_domains_for(target_domain)

            dataset = conn[:apollo_entries]
                      .where(status: 'confirmed', access_scope: 'global')
                      .where { confidence >= min_confidence }
                      .limit(limit)

            dataset = dataset.where(knowledge_domain: allowed) unless allowed == :all

            entries = dataset.all

            formatted = entries.map do |entry|
              { id: entry[:id], content: entry[:content], content_type: entry[:content_type],
                confidence: entry[:confidence], knowledge_domain: entry[:knowledge_domain],
                tags: storage_deserialize_tags(tags: entry[:tags]), source_agent: entry[:source_agent] }
            end

            { success: true, entries: formatted, count: formatted.size, target_domain: target_domain }
              .tap { |result| log.info("Apollo Knowledge.prepare_mesh_export results=#{result[:count]} target_domain=#{target_domain}") }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.knowledge.prepare_mesh_export')
            { success: false, error: e.message }
          end

          def handle_erasure_request(agent_id:, **)
            return { deleted: 0, redacted: 0, error: 'apollo_data_not_available' } unless Legion::Data.connection

            log.warn("Apollo Knowledge.handle_erasure_request agent_id=#{agent_id}")
            conn = Legion::Data.connection

            # Delete entries solely from dead agent (not confirmed by others)
            deleted = conn[:apollo_entries]
                      .where(source_agent: agent_id)
                      .exclude(status: 'confirmed')
                      .delete

            redacted = conn[:apollo_entries]
                       .where(source_agent: agent_id, status: 'confirmed')
                       .update(
                         source_agent:            'redacted',
                         source_provider:         nil,
                         source_channel:          nil,
                         identity_principal_id:   nil,
                         identity_id:             nil,
                         identity_canonical_name: nil
                       )

            { deleted: deleted, redacted: redacted, agent_id: agent_id }
              .tap { |result| log.info("Apollo Knowledge.handle_erasure_request deleted=#{result[:deleted]} redacted=#{result[:redacted]} agent_id=#{agent_id}") } # rubocop:disable Layout/LineLength
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.knowledge.handle_erasure_request')
            { deleted: 0, redacted: 0, error: e.message }
          end

          private

          def knowledge_persist_ingest(content:, content_type:, context:, metadata:, content_hash:, embedding:, provenance:, **)
            data_model_entry.db.transaction do
              corroborated, existing_id = knowledge_find_corroboration(
                embedding: embedding, provenance: provenance, content_type: content_type, metadata: metadata
              )
              unless corroborated
                existing_id = knowledge_create_candidate_entry(
                  content: content, content_type: content_type, context: context,
                  metadata: metadata, content_hash: content_hash, embedding: embedding, provenance: provenance
                )
              end
              raise Sequel::Error, 'entry_persistence_failed' unless existing_id

              knowledge_upsert_expertise(source_agent: metadata[:source_agent], domain: metadata[:domain])
              data_model_access_log.create(
                entry_id: existing_id, agent_id: metadata[:source_agent], action: 'ingest'
              )
              { success: true, entry_id: existing_id, status: corroborated ? 'corroborated' : 'candidate',
                corroborated: corroborated, contradictions: [] }
            end
          end

          def knowledge_ingest_early_return_error(content:, content_type:, tags:)
            if content.strip.empty?
              safe_tags = Array(tags).map(&:to_s).map { |t| t.gsub(/[\r\n]+/, ' ') }
              log.warn('[apollo][handle_ingest] early-return: content is required ' \
                       "content_type=#{content_type} tags=#{safe_tags.inspect}")
              return { success: false, error: 'content is required' }
            end

            missing = []
            missing << 'entry' if data_model_entry.nil?
            missing << 'expertise' if data_model_expertise.nil?
            missing << 'access_log' if data_model_access_log.nil?
            return nil if missing.empty?

            log.warn('[apollo][handle_ingest] early-return: apollo_data_not_available ' \
                     "content_type=#{content_type} missing=#{missing.join(',')}")
            { success: false, error: 'apollo_data_not_available' }
          end

          def knowledge_normalize_content_type(raw)
            sym = raw.to_s.delete_prefix(':').gsub(%r{[/\s]}, '_').strip.downcase.to_sym
            sym = CONTENT_TYPE_ALIASES.fetch(sym, sym)
            Legion::Extensions::Apollo::Helpers::Confidence::CONTENT_TYPES.include?(sym) ? sym : :observation
          end

          def knowledge_normalize_text_input(value)
            result = if defined?(Legion::Apollo) && Legion::Apollo.respond_to?(:normalize_text_input, true)
                       Legion::Apollo.send(:normalize_text_input, value)
                     else
                       value.to_s
                     end

            knowledge_sanitize_for_postgres(result)
          end

          def knowledge_sanitize_for_postgres(value)
            return value unless value.is_a?(String)

            string = value.encoding == Encoding::UTF_8 ? value.dup : value.dup.force_encoding(Encoding::UTF_8)
            changed = string.include?("\x00") || !string.valid_encoding?
            string = string.scrub('') unless string.valid_encoding?
            sanitized = string.delete("\x00")
            log.debug("Apollo Knowledge.sanitize_for_postgres sanitized original_length=#{value.bytesize} sanitized_length=#{sanitized.bytesize}") if changed
            sanitized
          end

          def knowledge_truncate_for_column(value, max_length)
            return nil if value.nil?

            knowledge_normalize_text_input(value)[0, max_length]
          end

          def knowledge_active_duplicate_for_hash(content_hash:, access_scope: nil, identity_principal_id: nil, **)
            return nil unless content_hash

            dataset = data_model_entry
                      .where(content_hash: content_hash, access_scope: access_scope)
                      .exclude(status: 'archived')

            dataset = dataset.where(identity_principal_id: identity_principal_id) if access_scope != 'global'

            existing = dataset.first
            log.debug("Apollo Knowledge.active_duplicate_for_hash matched entry_id=#{existing.id}") if existing
            existing
          end

          def knowledge_refresh_duplicate_embedding(entry:, **)
            provenance = embedding_parse_provenance(value: entry[:embedding_provenance])
            vector = similarity_parse_vector(vector: entry[:embedding])
            updates = { confidence: [entry.confidence + settings[:confidence][:retrieval_boost], 1.0].min, updated_at: Time.now }
            unless embedding_valid?(vector: vector, provenance: provenance, task: :document)
              document = Legion::Extensions::Apollo::Runners::Embedding.generate(text: entry.content, task: :document)
              db = data_model_entry.db
              updates.merge!(
                embedding: storage_serialize_embedding(db: db, vector: document[:vector]),
                embedding_provenance: storage_serialize_provenance(db: db, provenance: document[:provenance]),
                embedding_space_id: document[:provenance][:space_id], embedding_dimensions: document[:vector].length
              )
            end
            data_model_entry.db.transaction { entry.update(updates) }
          end

          def knowledge_ingest_metadata(tags:, knowledge_domain:, source_agent:, source_provider:, source_channel:, # rubocop:disable Metrics/ParameterLists
                                        submitted_by:, submitted_from:, access_scope: 'global',
                                        identity_principal_id: nil, identity_id: nil, identity_canonical_name: nil)
            tag_array = tag_normalize_all(tags: tags)
            agent = knowledge_truncate_for_column(source_agent, 50) || 'unknown'

            { tags:                    tag_array,
              domain:                  knowledge_truncate_for_column(knowledge_domain || tag_array.first || 'general', 50),
              source_agent:            agent,
              source_provider:         knowledge_truncate_for_column(source_provider || knowledge_derive_provider_from_agent(agent), 50),
              source_channel:          knowledge_truncate_for_column(source_channel, 100),
              submitted_by:            knowledge_truncate_for_column(submitted_by, 255),
              submitted_from:          knowledge_truncate_for_column(submitted_from, 255),
              access_scope:            (access_scope || 'global').to_s,
              identity_principal_id:   identity_principal_id.is_a?(Integer) ? identity_principal_id : nil,
              identity_id:             identity_id.is_a?(Integer) ? identity_id : nil,
              identity_canonical_name: identity_canonical_name&.to_s&.slice(0, 255) }
          end

          def knowledge_create_candidate_entry(content:, content_type:, context:, metadata:, content_hash:, embedding:, provenance:, **)
            entry_model = data_model_entry
            new_entry = entry_model.db.transaction(savepoint: true) do
              entry_model.create(
                content:                 content,
                content_type:            content_type,
                confidence:              settings[:confidence][:initial],
                source_agent:            metadata[:source_agent],
                source_provider:         metadata[:source_provider],
                source_channel:          metadata[:source_channel],
                source_context:          json_dump(context.is_a?(Hash) ? context : {}),
                tags:                    storage_serialize_tags(db: entry_model.db, tags: metadata[:tags]),
                status:                  'candidate',
                knowledge_domain:        metadata[:domain],
                submitted_by:            metadata[:submitted_by],
                submitted_from:          metadata[:submitted_from],
                content_hash:            content_hash,
                access_scope:            metadata[:access_scope] || 'global',
                identity_principal_id:   metadata[:identity_principal_id],
                identity_id:             metadata[:identity_id],
                identity_canonical_name: metadata[:identity_canonical_name],
                embedding:               storage_serialize_embedding(db: entry_model.db, vector: embedding),
                embedding_provenance:    storage_serialize_provenance(db: entry_model.db, provenance: provenance),
                embedding_space_id:      provenance[:space_id],
                embedding_dimensions:    embedding.length
              )
            end
            log.info("Apollo Knowledge.handle_ingest created entry_id=#{new_entry.id} status=candidate domain=#{metadata[:domain]} source_agent=#{metadata[:source_agent]} access_scope=#{metadata[:access_scope]}") # rubocop:disable Layout/LineLength
            new_entry.id
          rescue Sequel::UniqueConstraintViolation => e
            winner_scope = entry_model.where(content_hash: content_hash, access_scope: metadata[:access_scope]).exclude(status: 'archived')
            winner_scope = winner_scope.where(identity_principal_id: metadata[:identity_principal_id]) if metadata[:access_scope] != 'global'
            winner = winner_scope.first
            if winner
              log.warn("Apollo Knowledge.create_candidate_entry race_dedup entry_id=#{winner.id} content_hash=#{content_hash} error=#{e.message}")
              return winner.id
            end

            handle_exception(e, level: :error, operation: 'apollo.knowledge.create_candidate_entry', content_hash: content_hash)
            raise
          end

          def knowledge_browse_query?(query)
            query.to_s.strip.length < 3
          end

          def knowledge_list_entries_chronologically(query:, limit:, status:, status_defaulted:, tags:, domain:, # rubocop:disable Metrics/ParameterLists
                                                     min_confidence:, requesting_principal_id: nil, tag_match: :any, exclude_source_agents: [], **)
            log.debug("Apollo Knowledge.list_entries_chronologically limit=#{limit} statuses=#{Array(status).join(',')} status_defaulted=#{status_defaulted} tags=#{Array(tags).size} domain=#{domain || 'nil'}") # rubocop:disable Layout/LineLength
            dataset = data_model_entry.exclude(status: 'archived')
            requested = Array(status).map(&:to_s).reject(&:empty?)
            dataset = dataset.where(status: requested) unless status_defaulted || requested.empty?
            dataset = storage_filter_tags(dataset: dataset, tags: tags, tag_match: tag_match)
            dataset = dataset.where { confidence >= min_confidence }
            if Array(exclude_source_agents).any?
              dataset = dataset.where(Sequel.lit('(source_agent IS NULL OR source_agent NOT IN ?)', Array(exclude_source_agents).map(&:to_s)))
            end
            dataset = dataset.where(knowledge_domain: domain) unless domain.to_s.empty?

            if requesting_principal_id
              dataset = dataset.where(
                Sequel.lit(graph_access_scope_sql(global_only: requesting_principal_id.zero?),
                           requesting_principal_id: requesting_principal_id.to_i)
              )
            end

            entries = dataset.order(Sequel.desc(:created_at)).limit(limit).all.map do |entry|
              knowledge_format_entry(entry: entry.is_a?(Hash) ? entry : entry.values)
            end
            log.info("Apollo Knowledge.list_entries_chronologically results=#{entries.size}")
            { success: true, mode: :browse, query: query, entries: entries, count: entries.size }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.knowledge.list_entries_chronologically')
            { success: false, error: e.message }
          end

          def knowledge_format_entry(entry:, **)
            { id: entry[:id], content: entry[:content], content_type: entry[:content_type],
              confidence: entry[:confidence], distance: entry[:distance]&.to_f,
              tags: storage_deserialize_tags(tags: entry[:tags]), source_agent: entry[:source_agent],
              knowledge_domain: entry[:knowledge_domain] }
          end

          def knowledge_record_query_access(entry_id:, agent_id:)
            data_model_access_log.create(
              entry_id: entry_id, agent_id: agent_id, action: 'query'
            )
          end

          def knowledge_boost_entry_after_query(entry_model, entry)
            entry_model.where(id: entry[:id]).update(
              access_count: Sequel.expr(:access_count) + 1,
              confidence:   confidence_apply_retrieval_boost(confidence: entry[:confidence]),
              updated_at:   Time.now
            )
          end

          def knowledge_allowed_domains_for(target_domain)
            rules = settings[:domain_isolation]

            allowed = rules[target_domain]
            return :all if allowed == :all || allowed.nil?

            Array(allowed)
          end

          def knowledge_schedule_contradiction_detection(entry_id:, **)
            return unless settings[:contradiction][:enabled] == true
            return if data_model_entry.nil?

            Legion::Extensions::Apollo::Runners::Contradictions.enqueue(entry_id: entry_id)
            log.debug("Apollo Knowledge.schedule_contradiction_detection enqueued entry_id=#{entry_id}")
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.knowledge.schedule_contradiction_detection')
          end

          def knowledge_find_corroboration(embedding:, provenance:, content_type:, metadata:, **)
            return [false, nil] unless embedding
            return [false, nil] if metadata[:access_scope] != 'global' && metadata[:identity_principal_id].nil?

            source_agent = metadata[:source_agent]
            source_channel = metadata[:source_channel]
            scan_limit = settings[:corroboration][:scan_limit]
            # Candidate evidence is retained for the bounded maintenance bootstrap scan.
            existing = data_model_entry
                       .where(content_type: content_type, knowledge_domain: metadata[:domain],
                              access_scope: metadata[:access_scope], status: 'confirmed',
                              embedding_space_id: provenance[:space_id], embedding_dimensions: provenance[:dimensions])
                       .exclude(embedding: nil)
            existing = existing.where(identity_principal_id: metadata[:identity_principal_id]) if metadata[:access_scope] != 'global'
            existing = existing.limit(scan_limit)

            existing.each do |entry|
              stored_provenance = embedding_parse_provenance(value: entry[:embedding_provenance])
              stored_vector = similarity_parse_vector(vector: entry.embedding)
              next unless embedding_valid?(vector: stored_vector, provenance: stored_provenance, task: :document)
              next unless embedding_compatible?(left: provenance, right: stored_provenance)

              sim = similarity_cosine(vec_a: embedding, vec_b: stored_vector)
              next unless similarity_above_corroboration_threshold?(similarity: sim)

              same_provider_wt = settings[:corroboration][:same_provider_weight]
              weight = knowledge_same_source_provider?(source_agent, entry) ? same_provider_wt : 1.0

              # Reject corroboration entirely if same channel (same data source)
              if source_channel && entry.respond_to?(:source_channel)
                existing_channel = entry.source_channel
                weight = 0.0 if existing_channel && existing_channel == source_channel
              end
              next if weight.zero?

              entry.update(
                confidence: confidence_apply_corroboration_boost(confidence: entry.confidence, weight: weight),
                updated_at: Time.now
              )
              log.info("Apollo Knowledge.find_corroboration matched entry_id=#{entry.id} source_agent=#{source_agent} similarity=#{sim}")
              return [true, entry.id]
            end

            log.debug("Apollo Knowledge.find_corroboration no_match source_agent=#{source_agent}")
            [false, nil]
          end

          def knowledge_same_source_provider?(submitting_agent, entry)
            stored = entry.respond_to?(:source_provider) ? entry.source_provider : nil
            return false if stored.nil? || stored.to_s.empty? || stored.to_s == 'unknown'

            knowledge_derive_provider_from_agent(submitting_agent) == stored.to_s
          end

          def knowledge_derive_provider_from_agent(source_agent)
            return 'unknown' if source_agent.nil? || source_agent == 'unknown'

            provider = source_agent.to_s.split(/[-_]/).first.downcase
            %w[claude openai gemini human system].include?(provider) ? provider : 'unknown'
          end

          def knowledge_upsert_expertise(source_agent:, domain:)
            log.debug("Apollo Knowledge.upsert_expertise source_agent=#{source_agent} domain=#{domain}")
            expertise = data_model_expertise
                        .where(agent_id: source_agent, domain: domain).first
            if expertise
              expertise.update(entry_count: expertise.entry_count + 1, last_active_at: Time.now)
            else
              data_model_expertise.create(
                agent_id: source_agent, domain: domain,
                proficiency: settings[:expertise][:initial_proficiency],
                entry_count: 1, last_active_at: Time.now
              )
            end
          end

          def knowledge_resolve_process_identity(principal_id: UNSET, identity_id: UNSET, canonical_name: UNSET, **)
            unless principal_id.equal?(UNSET)
              return { principal_id:   principal_id,
                       identity_id:    identity_id.equal?(UNSET) ? nil : identity_id,
                       canonical_name: canonical_name.equal?(UNSET) ? nil : canonical_name }
            end
            return { principal_id: nil, identity_id: nil, canonical_name: nil } unless defined?(Legion::Identity::Process)

            {
              principal_id:   Legion::Identity::Process.db_principal_id,
              identity_id:    Legion::Identity::Process.db_identity_id,
              canonical_name: Legion::Identity::Process.canonical_name
            }
          end

          def knowledge_resolve_requesting_principal_id(explicit_value)
            return explicit_value if explicit_value
            return nil unless defined?(Legion::Identity::Process)

            Legion::Identity::Process.db_principal_id
          end
        end
      end
    end
  end
end
