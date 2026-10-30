# frozen_string_literal: true

require 'legion/json'
require 'legion/settings'
require_relative '../helpers/confidence'
require_relative '../helpers/data_models'
require_relative '../helpers/embedding'
require_relative '../helpers/storage'

module Legion
  module Extensions
    module Apollo
      module Runners
        module Knowledge
          DOMAIN_ISOLATION = {
            'claims_optimization' => ['claims_optimization'],
            'clinical_care'       => %w[clinical_care general],
            'general'             => :all
          }.freeze

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
            content_type = normalize_content_type(content_type)
            log.debug("Apollo Knowledge.store_knowledge content_type=#{content_type} tags=#{Array(tags).size} source_agent=#{source_agent || 'nil'} data_available=#{Helpers::DataModels.apollo_entry_available?}") # rubocop:disable Layout/LineLength

            if Helpers::DataModels.apollo_entry_available?
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

          def query_knowledge(query:, limit: Helpers::GraphQuery.default_query_limit, min_confidence: Helpers::GraphQuery.default_query_min_confidence, status: %i[confirmed candidate], tags: nil, **) # rubocop:disable Layout/LineLength
            log.debug("Apollo Knowledge.query_knowledge query_length=#{query.to_s.length} limit=#{limit} statuses=#{Array(status).join(',')} tags=#{Array(tags).size} data_available=#{Helpers::DataModels.apollo_entry_available?}") # rubocop:disable Layout/LineLength
            if Helpers::DataModels.apollo_entry_available?
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

          def related_entries(entry_id:, relation_types: nil, depth: Helpers::GraphQuery.default_depth, **)
            log.debug("Apollo Knowledge.related_entries entry_id=#{entry_id} depth=#{depth} relation_types=#{Array(relation_types).join(',')} data_available=#{Helpers::DataModels.apollo_entry_available?}") # rubocop:disable Layout/LineLength
            return handle_traverse(entry_id: entry_id, depth: depth, relation_types: relation_types, **) if Helpers::DataModels.apollo_entry_available?

            {
              action:         :traverse,
              entry_id:       entry_id,
              relation_types: relation_types,
              depth:          depth
            }
          end

          def deprecate_entry(entry_id:, reason:, requesting_principal_id: nil, **)
            return { action: :deprecate, entry_id: entry_id, reason: reason } unless Legion::Extensions::Apollo::Helpers::DataModels.apollo_entry_available?

            entry_model = Legion::Extensions::Apollo::Helpers::DataModels.apollo_entry
            requesting_principal_id = resolve_requesting_principal_id(requesting_principal_id)
            entry_model.db.transaction do
              entries = entry_model.for_update
              if requesting_principal_id
                entries = entries.where(Sequel.lit(Helpers::GraphQuery.access_scope_sql(global_only: requesting_principal_id.zero?),
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

          def handle_ingest(content: nil, content_type: nil, tags: [], source_agent: 'unknown', # rubocop:disable Metrics/ParameterLists
                            source_provider: nil, source_model: nil, source_channel: nil, knowledge_domain: nil,
                            submitted_by: nil, submitted_from: nil, content_hash: nil, context: {},
                            skip: false, access_scope: 'global', embedding: nil, embedding_provenance: nil,
                            identity_principal_id: UNSET, identity_id: UNSET, identity_canonical_name: UNSET, **)
            return { status: :skipped } if skip

            identity = resolve_process_identity(principal_id: identity_principal_id, identity_id: identity_id,
                                                canonical_name: identity_canonical_name)
            access_scope = (access_scope || 'global').to_s
            return { success: false, error: 'invalid_access_scope' } unless %w[global private team].include?(access_scope)
            if access_scope != 'global' && !(identity[:principal_id].is_a?(Integer) && identity[:principal_id].positive?)
              return { success: false, error: 'identity_required' }
            end

            content = normalize_text_input(content)
            content_type = normalize_content_type(content_type.nil? ? :observation : content_type)
            log.debug("Apollo Knowledge.handle_ingest content_length=#{content.length} content_type=#{content_type} tags=#{Array(tags).size} source_agent=#{source_agent} source_channel=#{source_channel || 'nil'}") # rubocop:disable Layout/LineLength
            early_error = ingest_early_return_error(content: content, content_type: content_type, tags: tags)
            return early_error if early_error

            hash = content_hash || Legion::Extensions::Apollo::Helpers::Writeback.content_hash(content: content)
            existing = active_duplicate_for_hash(content_hash: hash, access_scope: access_scope,
                                                 identity_principal_id: identity[:principal_id])
            if existing
              refresh_duplicate_embedding(entry: existing)
              log.info("Apollo Knowledge.handle_ingest deduped entry_id=#{existing.id} source_agent=#{source_agent}")
              return { success: true, entry_id: existing.id, deduped: true }
            end

            document = Legion::Extensions::Apollo::Helpers::Embedding.document(
              text: content, vector: embedding, provenance: embedding_provenance
            )
            metadata = ingest_metadata(tags: tags, knowledge_domain: knowledge_domain, source_agent: source_agent,
                                       source_provider: source_provider, source_channel: source_channel,
                                       submitted_by: submitted_by, submitted_from: submitted_from,
                                       access_scope: access_scope,
                                       identity_principal_id: identity[:principal_id],
                                       identity_id: identity[:identity_id],
                                       identity_canonical_name: identity[:canonical_name])

            context = (context.is_a?(Hash) ? context : {}).merge(source_model: source_model) unless source_model.nil?
            result = persist_ingest(content: content, content_type: content_type.to_s, context: context,
                                    metadata: metadata, content_hash: hash,
                                    embedding: document[:vector], provenance: document[:provenance])
            schedule_contradiction_detection(entry_id: result[:entry_id])
            log.debug("Apollo Knowledge.handle_ingest complete entry_id=#{result[:entry_id]} corroborated=#{result[:corroborated]}")
            result
          rescue Sequel::Error, Legion::Extensions::Apollo::Helpers::Embedding::Error => e
            handle_exception(e, level: :error, operation: 'apollo.knowledge.handle_ingest')
            { success: false, error: e.message }
          end

          def handle_query(query:, limit: Helpers::GraphQuery.default_query_limit, # rubocop:disable Metrics/CyclomaticComplexity, Metrics/ParameterLists
                           min_confidence: Helpers::GraphQuery.default_query_min_confidence,
                           status: UNSET, tags: nil, tag_match: :any, exclude_source_agents: [], domain: nil, agent_id: 'unknown',
                           requesting_principal_id: nil, **)
            return { success: false, error: 'apollo_data_not_available' } unless Helpers::DataModels.apollo_entry_available?
            return { success: false, error: 'invalid_tag_match' } unless %w[any all].include?(tag_match.to_s)

            requesting_principal_id = resolve_requesting_principal_id(requesting_principal_id)
            entry_model = Helpers::DataModels.apollo_entry
            query = normalize_text_input(query)
            status_defaulted = status.equal?(UNSET)
            requested_status = status_defaulted ? DEFAULT_QUERY_STATUS : status
            log.debug("Apollo Knowledge.handle_query query_length=#{query.length} limit=#{limit} statuses=#{requested_status.inspect} status_defaulted=#{status_defaulted} domain=#{domain.inspect} agent_id=#{agent_id}") # rubocop:disable Layout/LineLength
            if browse_query?(query)
              return list_entries_chronologically(query: query, limit: limit, status: requested_status,
                                                  status_defaulted: status_defaulted, tags: tags, domain: domain,
                                                  requesting_principal_id: requesting_principal_id, min_confidence: min_confidence,
                                                  tag_match: tag_match, exclude_source_agents: exclude_source_agents)
            end

            unless Helpers::DataModels.apollo_access_log_available?
              log.warn('Apollo Knowledge.handle_query skipped: apollo_data_not_available missing=access_log')
              return { success: false, error: 'apollo_data_not_available' }
            end

            embedding = embed_text(text: query, task: :query)
            if embedding.nil?
              log.warn('Apollo Knowledge.handle_query embedding unavailable; falling back to browse query')
              return list_entries_chronologically(query: query, limit: limit, status: requested_status,
                                                  status_defaulted: status_defaulted, tags: tags, domain: domain,
                                                  requesting_principal_id: requesting_principal_id, min_confidence: min_confidence,
                                                  tag_match: tag_match, exclude_source_agents: exclude_source_agents)
            end

            query_options = {
              limit: limit, min_confidence: min_confidence,
              statuses: Array(requested_status).map(&:to_s), tags: Array(tags).map(&:to_s),
              tag_match: tag_match, exclude_source_agents: Array(exclude_source_agents).map(&:to_s),
              domain: domain&.to_s, requesting_principal_id: requesting_principal_id&.to_i
            }
            entries = Legion::Extensions::Apollo::Helpers::Storage.semantic_search(
              db: entry_model.db, embedding: embedding[:vector], provenance: embedding[:provenance], **query_options
            )

            entries.each do |entry|
              boost_entry_after_query(entry_model, entry)
            end

            record_query_access(entry_id: entries.first[:id], agent_id: agent_id) if entries.any?

            formatted = entries.map { |entry| format_entry(entry: entry) }

            log.info("Apollo Knowledge.handle_query results=#{formatted.size} mode=semantic agent_id=#{agent_id}")
            { success: true, entries: formatted, count: formatted.size }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.knowledge.handle_query')
            { success: false, error: e.message }
          end

          def handle_traverse(entry_id:, depth: Helpers::GraphQuery.default_depth, relation_types: nil,
                              agent_id: 'unknown', requesting_principal_id: nil, **)
            return { success: false, error: 'apollo_data_not_available' } unless Helpers::DataModels.apollo_entry_available?

            if agent_id != 'unknown' && !Helpers::DataModels.apollo_access_log_available?
              log.warn('Apollo Knowledge.handle_traverse skipped: apollo_data_not_available missing=access_log')
              return { success: false, error: 'apollo_data_not_available' }
            end

            log.debug("Apollo Knowledge.handle_traverse entry_id=#{entry_id} depth=#{depth} relation_types=#{Array(relation_types).join(',')} agent_id=#{agent_id}") # rubocop:disable Layout/LineLength
            # Keep traversal limited to the supported relation vocabulary.
            if relation_types
              allowed = Helpers::Confidence::RELATION_TYPES
              relation_types = relation_types.map(&:to_s).select { |type| allowed.include?(type) }
            end

            requesting_principal_id = resolve_requesting_principal_id(requesting_principal_id)
            sql = Helpers::GraphQuery.build_traversal_sql(depth: depth, relation_types: relation_types,
                                                          requesting_principal_id: requesting_principal_id)
            db = Helpers::DataModels.apollo_entry.db
            entries = db.fetch(sql, entry_id: entry_id, depth: depth, relation_types: relation_types,
                                   requesting_principal_id: requesting_principal_id,
                                   spread_factor: Helpers::GraphQuery.spread_factor,
                                   min_activation: Helpers::GraphQuery.min_activation).all

            if entries.any? && agent_id != 'unknown'
              Helpers::DataModels.apollo_access_log.create(
                entry_id: entry_id, agent_id: agent_id, action: 'query'
              )
            end

            formatted = entries.map do |entry|
              { id: entry[:id], content: entry[:content], content_type: entry[:content_type],
                confidence: entry[:confidence], tags: Legion::Extensions::Apollo::Helpers::Storage.deserialize_tags(tags: entry[:tags]),
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
            return { success: false, error: 'apollo_data_not_available' } unless Helpers::DataModels.apollo_entry_available?

            log.debug("Apollo Knowledge.redistribute_knowledge agent_id=#{agent_id} min_confidence=#{min_confidence}")
            entries = Helpers::DataModels.apollo_entry
                                         .where(source_agent: agent_id, status: 'confirmed')
                                         .where { confidence > min_confidence }
                                         .all

            return { success: true, redistributed: 0 } if entries.empty?

            store = (Legion::Extensions::Agentic::Memory::Trace.shared_store if defined?(Legion::Extensions::Agentic::Memory::Trace))

            redistributed = 0
            entries.each do |entry|
              if store
                tags = Legion::Extensions::Apollo::Helpers::Storage.deserialize_tags(tags: entry.tags)
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
                                min_confidence: Helpers::GraphQuery.default_query_min_confidence,
                                status: %i[confirmed candidate], tags: nil, tag_match: :any, exclude_source_agents: [], domain: nil,
                                skip: false, requesting_principal_id: nil, **)
            return { status: :skipped } if skip

            return { success: false, error: 'apollo_data_not_available' } unless Helpers::DataModels.apollo_entry_available?
            return { success: false, error: 'invalid_tag_match' } unless %w[any all].include?(tag_match.to_s)

            requesting_principal_id = resolve_requesting_principal_id(requesting_principal_id)
            query = normalize_text_input(query)
            log.debug("Apollo Knowledge.retrieve_relevant query_length=#{query.length} limit=#{limit} min_confidence=#{min_confidence} tags=#{Array(tags).size} domain=#{domain.inspect}") # rubocop:disable Layout/LineLength
            return { success: true, entries: [], count: 0 } if query.to_s.strip.empty?

            embedding = embed_text(text: query, task: :query)
            if embedding.nil?
              log.warn('Apollo Knowledge.retrieve_relevant embedding unavailable; returning empty result')
              return { success: true, entries: [], count: 0, degraded: :no_embedding }
            end

            query_options = {
              limit: limit, min_confidence: min_confidence,
              statuses: Array(status).map(&:to_s), tags: Array(tags).map(&:to_s),
              tag_match: tag_match, exclude_source_agents: Array(exclude_source_agents).map(&:to_s),
              domain: domain&.to_s, requesting_principal_id: requesting_principal_id&.to_i
            }
            entries = Legion::Extensions::Apollo::Helpers::Storage.semantic_search(
              db: Helpers::DataModels.apollo_entry.db,
              embedding: embedding[:vector], provenance: embedding[:provenance], **query_options
            )

            entries.each do |entry|
              Helpers::DataModels.apollo_entry.where(id: entry[:id]).update(
                confidence: Helpers::Confidence.apply_retrieval_boost(confidence: entry[:confidence]),
                updated_at: Time.now
              )
            end

            formatted = entries.map { |entry| format_entry(entry: entry) }

            log.info("Apollo Knowledge.retrieve_relevant results=#{formatted.size} limit=#{limit}")
            { success: true, entries: formatted, count: formatted.size }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.knowledge.retrieve_relevant')
            { success: false, error: e.message }
          end

          def prepare_mesh_export(target_domain:, min_confidence: settings[:query][:mesh_export_min_confidence], limit: settings[:query][:mesh_export_limit], **) # rubocop:disable Layout/LineLength
            unless defined?(Legion::Data) && Legion::Data.respond_to?(:connection) && Legion::Data.connection
              return { success: false, error: 'apollo_data_not_available' }
            end

            log.debug("Apollo Knowledge.prepare_mesh_export target_domain=#{target_domain} min_confidence=#{min_confidence} limit=#{limit}")
            conn = Legion::Data.connection
            allowed = allowed_domains_for(target_domain)

            dataset = conn[:apollo_entries]
                      .where(status: 'confirmed', access_scope: 'global')
                      .where { confidence >= min_confidence }
                      .limit(limit)

            dataset = dataset.where(knowledge_domain: allowed) unless allowed == :all

            entries = dataset.all

            formatted = entries.map do |entry|
              { id: entry[:id], content: entry[:content], content_type: entry[:content_type],
                confidence: entry[:confidence], knowledge_domain: entry[:knowledge_domain],
                tags: Legion::Extensions::Apollo::Helpers::Storage.deserialize_tags(tags: entry[:tags]), source_agent: entry[:source_agent] }
            end

            { success: true, entries: formatted, count: formatted.size, target_domain: target_domain }
              .tap { |result| log.info("Apollo Knowledge.prepare_mesh_export results=#{result[:count]} target_domain=#{target_domain}") }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.knowledge.prepare_mesh_export')
            { success: false, error: e.message }
          end

          def handle_erasure_request(agent_id:, **)
            unless defined?(Legion::Data) && Legion::Data.respond_to?(:connection) && Legion::Data.connection
              return { deleted: 0, redacted: 0, error: 'apollo_data_not_available' }
            end

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

          CONFLICT_CHECK_MAX_CHARS = 4000

          private

          def persist_ingest(content:, content_type:, context:, metadata:, content_hash:, embedding:, provenance:, **)
            Helpers::DataModels.apollo_entry.db.transaction do
              corroborated, existing_id = find_corroboration(
                embedding: embedding, provenance: provenance, content_type: content_type, metadata: metadata
              )
              unless corroborated
                existing_id = create_candidate_entry(
                  content: content, content_type: content_type, context: context,
                  metadata: metadata, content_hash: content_hash, embedding: embedding, provenance: provenance
                )
              end
              raise Sequel::Error, 'entry_persistence_failed' unless existing_id

              upsert_expertise(source_agent: metadata[:source_agent], domain: metadata[:domain])
              Helpers::DataModels.apollo_access_log.create(
                entry_id: existing_id, agent_id: metadata[:source_agent], action: 'ingest'
              )
              { success: true, entry_id: existing_id, status: corroborated ? 'corroborated' : 'candidate',
                corroborated: corroborated, contradictions: [] }
            end
          end

          def ingest_early_return_error(content:, content_type:, tags:)
            if content.strip.empty?
              safe_tags = Array(tags).map(&:to_s).map { |t| t.gsub(/[\r\n]+/, ' ') }
              log.warn('[apollo][handle_ingest] early-return: content is required ' \
                       "content_type=#{content_type} tags=#{safe_tags.inspect}")
              return { success: false, error: 'content is required' }
            end

            missing = []
            missing << 'entry' unless Helpers::DataModels.apollo_entry_available?
            missing << 'expertise' unless Helpers::DataModels.apollo_expertise_available?
            missing << 'access_log' unless Helpers::DataModels.apollo_access_log_available?
            return nil if missing.empty?

            log.warn('[apollo][handle_ingest] early-return: apollo_data_not_available ' \
                     "content_type=#{content_type} missing=#{missing.join(',')}")
            { success: false, error: 'apollo_data_not_available' }
          end

          def normalize_content_type(raw)
            sym = raw.to_s.delete_prefix(':').gsub(%r{[/\s]}, '_').strip.downcase.to_sym
            sym = CONTENT_TYPE_ALIASES.fetch(sym, sym)
            Helpers::Confidence::CONTENT_TYPES.include?(sym) ? sym : :observation
          end

          def embed_text(text:, task: :document, **)
            Legion::Extensions::Apollo::Helpers::Embedding.generate(text: normalize_text_input(text), task: task)
          rescue Legion::Extensions::Apollo::Helpers::Embedding::Error => e
            handle_exception(e, level: :warn, operation: 'apollo.knowledge.embed_text')
            nil
          end

          def normalize_text_input(value)
            result = if defined?(Legion::Apollo) && Legion::Apollo.respond_to?(:normalize_text_input, true)
                       Legion::Apollo.send(:normalize_text_input, value)
                     else
                       value.to_s
                     end

            sanitize_for_postgres(result)
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.knowledge.normalize_text_input')
            ''
          end

          def sanitize_for_postgres(value)
            return value unless value.is_a?(String)

            string = value.encoding == Encoding::UTF_8 ? value.dup : value.dup.force_encoding(Encoding::UTF_8)
            changed = string.include?("\x00") || !string.valid_encoding?
            string = string.scrub('') unless string.valid_encoding?
            sanitized = string.delete("\x00")
            log.debug("Apollo Knowledge.sanitize_for_postgres sanitized original_length=#{value.bytesize} sanitized_length=#{sanitized.bytesize}") if changed
            sanitized
          end

          def truncate_for_column(value, max_length)
            return nil if value.nil?

            normalize_text_input(value)[0, max_length]
          end

          def active_duplicate_for_hash(content_hash:, access_scope: nil, identity_principal_id: nil, **)
            return nil unless content_hash

            dataset = Helpers::DataModels.apollo_entry
                                         .where(content_hash: content_hash, access_scope: access_scope)
                                         .exclude(status: 'archived')

            dataset = dataset.where(identity_principal_id: identity_principal_id) if access_scope != 'global'

            existing = dataset.first
            log.debug("Apollo Knowledge.active_duplicate_for_hash matched entry_id=#{existing.id}") if existing
            existing
          end

          def refresh_duplicate_embedding(entry:, **)
            provenance = Legion::Extensions::Apollo::Helpers::Embedding.parse_provenance(value: entry[:embedding_provenance])
            vector = Legion::Extensions::Apollo::Helpers::Similarity.parse_vector(vector: entry[:embedding])
            updates = { confidence: [entry.confidence + Helpers::Confidence.retrieval_boost, 1.0].min, updated_at: Time.now }
            unless Legion::Extensions::Apollo::Helpers::Embedding.valid?(vector: vector, provenance: provenance, task: :document)
              document = Legion::Extensions::Apollo::Helpers::Embedding.generate(text: entry.content, task: :document)
              db = Helpers::DataModels.apollo_entry.db
              updates.merge!(
                embedding: Legion::Extensions::Apollo::Helpers::Storage.serialize_embedding(db: db, vector: document[:vector]),
                embedding_provenance: Legion::Extensions::Apollo::Helpers::Storage.serialize_provenance(db: db, provenance: document[:provenance]),
                embedding_space_id: document[:provenance][:space_id], embedding_dimensions: document[:vector].length
              )
            end
            Helpers::DataModels.apollo_entry.db.transaction { entry.update(updates) }
          end

          def ingest_metadata(tags:, knowledge_domain:, source_agent:, source_provider:, source_channel:, # rubocop:disable Metrics/ParameterLists
                              submitted_by:, submitted_from:, access_scope: 'global',
                              identity_principal_id: nil, identity_id: nil, identity_canonical_name: nil)
            tag_array = defined?(Helpers::TagNormalizer) ? Helpers::TagNormalizer.normalize_all(tags) : Array(tags)
            agent = truncate_for_column(source_agent, 50) || 'unknown'

            { tags:                    tag_array,
              domain:                  truncate_for_column(knowledge_domain || tag_array.first || 'general', 50),
              source_agent:            agent,
              source_provider:         truncate_for_column(source_provider || derive_provider_from_agent(agent), 50),
              source_channel:          truncate_for_column(source_channel, 100),
              submitted_by:            truncate_for_column(submitted_by, 255),
              submitted_from:          truncate_for_column(submitted_from, 255),
              access_scope:            (access_scope || 'global').to_s,
              identity_principal_id:   identity_principal_id.is_a?(Integer) ? identity_principal_id : nil,
              identity_id:             identity_id.is_a?(Integer) ? identity_id : nil,
              identity_canonical_name: identity_canonical_name&.to_s&.slice(0, 255) }
          end

          def create_candidate_entry(content:, content_type:, context:, metadata:, content_hash:, embedding:, provenance:, **)
            entry_model = Helpers::DataModels.apollo_entry
            new_entry = entry_model.db.transaction(savepoint: true) do
              entry_model.create(
                content:                 content,
                content_type:            content_type,
                confidence:              Helpers::Confidence.initial_confidence,
                source_agent:            metadata[:source_agent],
                source_provider:         metadata[:source_provider],
                source_channel:          metadata[:source_channel],
                source_context:          json_dump(context.is_a?(Hash) ? context : {}),
                tags:                    Legion::Extensions::Apollo::Helpers::Storage.serialize_tags(db: entry_model.db, tags: metadata[:tags]),
                status:                  'candidate',
                knowledge_domain:        metadata[:domain],
                submitted_by:            metadata[:submitted_by],
                submitted_from:          metadata[:submitted_from],
                content_hash:            content_hash,
                access_scope:            metadata[:access_scope] || 'global',
                identity_principal_id:   metadata[:identity_principal_id],
                identity_id:             metadata[:identity_id],
                identity_canonical_name: metadata[:identity_canonical_name],
                embedding:               Legion::Extensions::Apollo::Helpers::Storage.serialize_embedding(db: entry_model.db, vector: embedding),
                embedding_provenance:    Legion::Extensions::Apollo::Helpers::Storage.serialize_provenance(db: entry_model.db, provenance: provenance),
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

          def browse_query?(query)
            query.to_s.strip.length < 3
          end

          def list_entries_chronologically(query:, limit:, status:, status_defaulted:, tags:, domain:, # rubocop:disable Metrics/ParameterLists
                                           min_confidence:, requesting_principal_id: nil, tag_match: :any, exclude_source_agents: [], **)
            log.debug("Apollo Knowledge.list_entries_chronologically limit=#{limit} statuses=#{Array(status).join(',')} status_defaulted=#{status_defaulted} tags=#{Array(tags).size} domain=#{domain || 'nil'}") # rubocop:disable Layout/LineLength
            dataset = Helpers::DataModels.apollo_entry.exclude(status: 'archived')
            requested = Array(status).map(&:to_s).reject(&:empty?)
            dataset = dataset.where(status: requested) unless status_defaulted || requested.empty?
            dataset = Legion::Extensions::Apollo::Helpers::Storage.filter_tags(dataset: dataset, tags: tags, tag_match: tag_match)
            dataset = dataset.where { confidence >= min_confidence }
            if Array(exclude_source_agents).any?
              dataset = dataset.where(Sequel.lit('(source_agent IS NULL OR source_agent NOT IN ?)', Array(exclude_source_agents).map(&:to_s)))
            end
            dataset = dataset.where(knowledge_domain: domain) unless domain.to_s.empty?

            if requesting_principal_id
              dataset = dataset.where(
                Sequel.lit(Legion::Extensions::Apollo::Helpers::GraphQuery.access_scope_sql(global_only: requesting_principal_id.zero?),
                           requesting_principal_id: requesting_principal_id.to_i)
              )
            end

            entries = dataset.order(Sequel.desc(:created_at)).limit(limit).all.map do |entry|
              format_entry(entry: entry.is_a?(Hash) ? entry : entry.values)
            end
            log.info("Apollo Knowledge.list_entries_chronologically results=#{entries.size}")
            { success: true, mode: :browse, query: query, entries: entries, count: entries.size }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.knowledge.list_entries_chronologically')
            { success: false, error: e.message }
          end

          def format_entry(entry:, **)
            { id: entry[:id], content: entry[:content], content_type: entry[:content_type],
              confidence: entry[:confidence], distance: entry[:distance]&.to_f,
              tags: Legion::Extensions::Apollo::Helpers::Storage.deserialize_tags(tags: entry[:tags]), source_agent: entry[:source_agent],
              knowledge_domain: entry[:knowledge_domain] }
          end

          def record_query_access(entry_id:, agent_id:)
            Helpers::DataModels.apollo_access_log.create(
              entry_id: entry_id, agent_id: agent_id, action: 'query'
            )
          end

          def boost_entry_after_query(entry_model, entry)
            entry_model.where(id: entry[:id]).update(
              access_count: Sequel.expr(:access_count) + 1,
              confidence:   Helpers::Confidence.apply_retrieval_boost(
                confidence: entry[:confidence]
              ),
              updated_at:   Time.now
            )
          end

          def settings
            Legion::Extensions::Apollo.settings
          end

          def allowed_domains_for(target_domain)
            rules = settings[:domain_isolation]

            allowed = rules[target_domain]
            return :all if allowed == :all || allowed.nil?

            Array(allowed)
          end

          def contradiction_detection_enabled?
            settings[:contradiction][:enabled] == true
          end

          def schedule_contradiction_detection(entry_id:, **)
            return unless contradiction_detection_enabled?
            return unless Helpers::DataModels.apollo_entry_available?

            Legion::Extensions::Apollo::Actor::ContradictionScanner.enqueue(entry_id: entry_id)
            log.debug("Apollo Knowledge.schedule_contradiction_detection enqueued entry_id=#{entry_id}")
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.knowledge.schedule_contradiction_detection')
          end

          def detect_contradictions(entry_id:, **)
            return [] unless Helpers::DataModels.apollo_entry_available?

            entry_model = Helpers::DataModels.apollo_entry
            entry = entry_model[entry_id]
            return [] unless entry && entry.status != 'archived'

            provenance = Legion::Extensions::Apollo::Helpers::Embedding.parse_provenance(value: entry[:embedding_provenance])
            embedding = Legion::Extensions::Apollo::Helpers::Similarity.parse_vector(vector: entry[:embedding])
            return [] unless Legion::Extensions::Apollo::Helpers::Embedding.valid?(vector: embedding, provenance: provenance, task: :document)
            return [] if entry.access_scope != 'global' && !entry.identity_principal_id.to_i.positive?

            sim_limit = settings[:contradiction][:similar_limit]
            sim_threshold = settings[:contradiction][:similarity_threshold]
            rel_weight = settings[:contradiction][:relation_weight]
            db = entry_model.db
            similar = Legion::Extensions::Apollo::Helpers::Storage.semantic_search(
              db: db, embedding: embedding, provenance: provenance, limit: sim_limit + 1,
              min_confidence: 0.0, statuses: %w[candidate confirmed], domain: entry.knowledge_domain,
              access_scope: entry.access_scope, identity_principal_id: entry.identity_principal_id
            )

            contradictions = []
            similar.each do |existing|
              next if existing[:id] == entry_id
              next unless 1.0 - existing[:distance] > sim_threshold
              next unless llm_detects_conflict?(content_a: entry.content, content_b: existing[:content])

              contradictions << existing[:id]
            end
            unless contradictions.empty?
              db.transaction do
                contradictions.each do |contradicted_id|
                  Legion::Extensions::Apollo::Helpers::DataModels.apollo_relation.create(
                    from_entry_id: entry_id, to_entry_id: contradicted_id,
                    relation_type: 'contradicts', source_agent: 'system:contradiction', weight: rel_weight
                  )
                end
                Legion::Extensions::Apollo::Helpers::DataModels.apollo_entry
                                                               .where(id: [entry_id, *contradictions]).update(status: 'disputed')
              end
            end
            log.info("Apollo Knowledge.detect_contradictions entry_id=#{entry_id} contradictions=#{contradictions.size}") if contradictions.any?
            contradictions
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.knowledge.detect_contradictions')
            raise
          end

          def llm_detects_conflict?(content_a:, content_b:, **)
            return false unless defined?(Legion::LLM) && Legion::LLM.respond_to?(:structured)

            a = content_a.to_s[0, CONFLICT_CHECK_MAX_CHARS]
            b = content_b.to_s[0, CONFLICT_CHECK_MAX_CHARS]
            result = Legion::LLM.structured(
              messages: [
                { role: 'system', content: 'Do these two statements contradict each other? Return JSON.' },
                { role: 'user', content: "A: #{a}\n\nB: #{b}" }
              ],
              schema:   { type: 'object', properties: { contradicts: { type: 'boolean' } } },
              caller:   { extension: 'lex-apollo', runner: 'knowledge' }
            )
            result[:data]&.dig(:contradicts) == true
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.knowledge.llm_detects_conflict')
            false
          end

          def find_corroboration(embedding:, provenance:, content_type:, metadata:, **)
            return [false, nil] unless embedding
            return [false, nil] if metadata[:access_scope] != 'global' && metadata[:identity_principal_id].nil?

            source_agent = metadata[:source_agent]
            source_channel = metadata[:source_channel]
            scan_limit = settings[:corroboration][:scan_limit]
            # Candidate evidence is retained for the bounded maintenance bootstrap scan.
            existing = Helpers::DataModels.apollo_entry
                                          .where(content_type: content_type, knowledge_domain: metadata[:domain],
                                                 access_scope: metadata[:access_scope], status: 'confirmed',
                                                 embedding_space_id: provenance[:space_id], embedding_dimensions: provenance[:dimensions])
                                          .exclude(embedding: nil)
            existing = existing.where(identity_principal_id: metadata[:identity_principal_id]) if metadata[:access_scope] != 'global'
            existing = existing.limit(scan_limit)

            existing.each do |entry|
              stored_provenance = Legion::Extensions::Apollo::Helpers::Embedding.parse_provenance(value: entry[:embedding_provenance])
              stored_vector = Legion::Extensions::Apollo::Helpers::Similarity.parse_vector(vector: entry.embedding)
              next unless Legion::Extensions::Apollo::Helpers::Embedding.valid?(vector: stored_vector, provenance: stored_provenance, task: :document)
              next unless Legion::Extensions::Apollo::Helpers::Embedding.compatible?(left: provenance, right: stored_provenance)

              sim = Helpers::Similarity.cosine_similarity(vec_a: embedding, vec_b: stored_vector)
              next unless Helpers::Similarity.above_corroboration_threshold?(similarity: sim)

              same_provider_wt = settings[:corroboration][:same_provider_weight]
              weight = same_source_provider?(source_agent, entry) ? same_provider_wt : 1.0

              # Reject corroboration entirely if same channel (same data source)
              if source_channel && entry.respond_to?(:source_channel)
                existing_channel = entry.source_channel
                weight = 0.0 if existing_channel && existing_channel == source_channel
              end
              next if weight.zero?

              entry.update(
                confidence: Helpers::Confidence.apply_corroboration_boost(confidence: entry.confidence, weight: weight),
                updated_at: Time.now
              )
              log.info("Apollo Knowledge.find_corroboration matched entry_id=#{entry.id} source_agent=#{source_agent} similarity=#{sim}")
              return [true, entry.id]
            end

            log.debug("Apollo Knowledge.find_corroboration no_match source_agent=#{source_agent}")
            [false, nil]
          end

          def same_source_provider?(submitting_agent, entry)
            stored = entry.respond_to?(:source_provider) ? entry.source_provider : nil
            return false if stored.nil? || stored.to_s.empty? || stored.to_s == 'unknown'

            derive_provider_from_agent(submitting_agent) == stored.to_s
          end

          def derive_provider_from_agent(source_agent)
            return 'unknown' if source_agent.nil? || source_agent == 'unknown'

            provider = source_agent.to_s.split(/[-_]/).first.downcase
            %w[claude openai gemini human system].include?(provider) ? provider : 'unknown'
          end

          def upsert_expertise(source_agent:, domain:)
            log.debug("Apollo Knowledge.upsert_expertise source_agent=#{source_agent} domain=#{domain}")
            expertise = Helpers::DataModels.apollo_expertise
                                           .where(agent_id: source_agent, domain: domain).first
            if expertise
              expertise.update(entry_count: expertise.entry_count + 1, last_active_at: Time.now)
            else
              Helpers::DataModels.apollo_expertise.create(
                agent_id: source_agent, domain: domain,
                proficiency: settings[:expertise][:initial_proficiency],
                entry_count: 1, last_active_at: Time.now
              )
            end
          end

          def resolve_process_identity(principal_id: UNSET, identity_id: UNSET, canonical_name: UNSET, **)
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
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.knowledge.resolve_process_identity')
            { principal_id: nil, identity_id: nil, canonical_name: nil }
          end

          def resolve_requesting_principal_id(explicit_value)
            return explicit_value if explicit_value
            return nil unless defined?(Legion::Identity::Process)

            Legion::Identity::Process.db_principal_id
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.knowledge.resolve_requesting_principal_id')
            nil
          end

          include Legion::Extensions::Helpers::Lex if defined?(Legion::Extensions::Helpers::Lex)
          include Legion::JSON::Helper
          include Legion::Settings::Helper
          extend Legion::Extensions::Helpers::Lex if defined?(Legion::Extensions::Helpers::Lex)
          extend Legion::JSON::Helper
          extend Legion::Settings::Helper
        end
      end
    end
  end
end
