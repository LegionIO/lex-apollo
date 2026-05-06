# frozen_string_literal: true

require 'legion/json'
require 'legion/settings'
require_relative '../helpers/confidence'
require_relative '../helpers/data_models'

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

          def deprecate_entry(entry_id:, reason:, **)
            {
              action:   :deprecate,
              entry_id: entry_id,
              reason:   reason
            }
          end

          def handle_ingest(content: nil, content_type: nil, tags: [], source_agent: 'unknown', source_provider: nil, source_channel: nil, knowledge_domain: nil, submitted_by: nil, submitted_from: nil, content_hash: nil, context: {}, skip: false, **) # rubocop:disable Metrics/ParameterLists, Layout/LineLength
            return { status: :skipped } if skip

            content = normalize_text_input(content)
            content_type = normalize_content_type(content_type.nil? ? :observation : content_type)
            log.debug("Apollo Knowledge.handle_ingest content_length=#{content.length} content_type=#{content_type} tags=#{Array(tags).size} source_agent=#{source_agent} source_channel=#{source_channel || 'nil'}") # rubocop:disable Layout/LineLength
            early_error = ingest_early_return_error(content: content, content_type: content_type, tags: tags)
            return early_error if early_error

            hash = content_hash || (defined?(Helpers::Writeback) ? Helpers::Writeback.content_hash(content) : nil)
            existing = active_duplicate_for_hash(hash)
            if existing
              log.info("Apollo Knowledge.handle_ingest deduped entry_id=#{existing.id} source_agent=#{source_agent}")
              return { success: true, entry_id: existing.id, deduped: true }
            end

            embedding = embed_text(content)
            content_type_sym = content_type.to_s
            metadata = ingest_metadata(tags: tags, knowledge_domain: knowledge_domain, source_agent: source_agent,
                                       source_provider: source_provider, source_channel: source_channel,
                                       submitted_by: submitted_by, submitted_from: submitted_from)

            corroborated, existing_id = find_corroboration(
              embedding, content_type_sym, metadata[:source_agent], metadata[:source_channel]
            )

            if corroborated
              log.info("Apollo Knowledge.handle_ingest corroborated entry_id=#{existing_id} source_agent=#{metadata[:source_agent]}")
            else
              existing_id = create_candidate_entry(
                content: content, content_type: content_type_sym, context: context,
                metadata: metadata, content_hash: hash, embedding: embedding
              )
            end

            upsert_expertise(source_agent: metadata[:source_agent], domain: metadata[:domain])

            Helpers::DataModels.apollo_access_log.create(
              entry_id: existing_id, agent_id: metadata[:source_agent], action: 'ingest'
            )

            contradictions = detect_contradictions(existing_id, embedding, content)
            log.debug("Apollo Knowledge.handle_ingest complete entry_id=#{existing_id} corroborated=#{corroborated} contradictions=#{contradictions.size}")

            { success: true, entry_id: existing_id, status: corroborated ? 'corroborated' : 'candidate',
              corroborated: corroborated, contradictions: contradictions }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.knowledge.handle_ingest')
            { success: false, error: e.message }
          end

          def handle_query(query:, limit: Helpers::GraphQuery.default_query_limit, min_confidence: Helpers::GraphQuery.default_query_min_confidence, status: UNSET, tags: nil, domain: nil, agent_id: 'unknown', **) # rubocop:disable Layout/LineLength
            return { success: false, error: 'apollo_data_not_available' } unless Helpers::DataModels.apollo_entry_available?

            entry_model = Helpers::DataModels.apollo_entry
            query = normalize_text_input(query)
            status_defaulted = status.equal?(UNSET)
            requested_status = status_defaulted ? DEFAULT_QUERY_STATUS : status
            log.debug("Apollo Knowledge.handle_query mode=#{browse_query?(query) ? 'browse' : 'semantic'} query_length=#{query.length} limit=#{limit} statuses=#{Array(requested_status).join(',')} status_defaulted=#{status_defaulted} tags=#{Array(tags).size} domain=#{domain || 'nil'} agent_id=#{agent_id}") # rubocop:disable Layout/LineLength
            if browse_query?(query)
              return list_entries_chronologically(query: query, limit: limit, status: requested_status,
                                                  status_defaulted: status_defaulted, tags: tags, domain: domain)
            end

            embedding = embed_text(query)
            sql = Helpers::GraphQuery.build_semantic_search_sql(
              limit: limit, min_confidence: min_confidence,
              statuses: Array(requested_status).map(&:to_s), tags: tags, domain: domain
            )

            db = entry_model.db
            entries = db.fetch(sql, embedding: Sequel.lit("'[#{embedding.join(',')}]'::vector")).all

            entries = entries.reject { |e| e[:distance].respond_to?(:nan?) && e[:distance].nan? }

            entries.each do |entry|
              boost_entry_after_query(entry_model, entry)
            end

            record_query_access(entry_id: entries.first&.dig(:id), agent_id: agent_id) if entries.any?

            formatted = entries.map do |entry|
              { id: entry[:id], content: entry[:content], content_type: entry[:content_type],
                confidence: entry[:confidence], distance: entry[:distance]&.to_f,
                tags: entry[:tags], source_agent: entry[:source_agent],
                knowledge_domain: entry[:knowledge_domain] }
            end

            log.info("Apollo Knowledge.handle_query results=#{formatted.size} mode=semantic agent_id=#{agent_id}")
            { success: true, entries: formatted, count: formatted.size }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.knowledge.handle_query')
            { success: false, error: e.message }
          end

          def handle_traverse(entry_id:, depth: Helpers::GraphQuery.default_depth, relation_types: nil, agent_id: 'unknown', **)
            return { success: false, error: 'apollo_data_not_available' } unless Helpers::DataModels.apollo_entry_available?

            log.debug("Apollo Knowledge.handle_traverse entry_id=#{entry_id} depth=#{depth} relation_types=#{Array(relation_types).join(',')} agent_id=#{agent_id}") # rubocop:disable Layout/LineLength
            # Whitelist relation_types to prevent SQL injection (they are string-interpolated in build_traversal_sql)
            if relation_types
              allowed = Helpers::Confidence::RELATION_TYPES
              relation_types = relation_types.select { |t| allowed.include?(t.to_s) }
            end

            sql = Helpers::GraphQuery.build_traversal_sql(depth: depth, relation_types: relation_types)
            db = Helpers::DataModels.apollo_entry.db
            entries = db.fetch(sql, entry_id: entry_id).all

            if entries.any? && agent_id != 'unknown'
              Helpers::DataModels.apollo_access_log.create(
                entry_id: entry_id, agent_id: agent_id, action: 'query'
              )
            end

            formatted = entries.map do |entry|
              { id: entry[:id], content: entry[:content], content_type: entry[:content_type],
                confidence: entry[:confidence], tags: entry[:tags], source_agent: entry[:source_agent],
                depth: entry[:depth], activation: entry[:activation] }
            end

            log.info("Apollo Knowledge.handle_traverse results=#{formatted.size} entry_id=#{entry_id}")
            { success: true, entries: formatted, count: formatted.size }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.knowledge.handle_traverse')
            { success: false, error: e.message }
          end

          def redistribute_knowledge(agent_id:, min_confidence: Helpers::Confidence.apollo_setting(:query, :redistribute_min_confidence, default: 0.5), **)
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
                trace = Legion::Extensions::Agentic::Memory::Trace::Helpers::Trace.new_trace(
                  type:            :semantic,
                  content_payload: { content: entry.content, source_agent: agent_id,
                                     content_type: entry.content_type, tags: Array(entry.tags) },
                  strength:        entry.confidence.to_f,
                  domain_tag:      Array(entry.tags).first || 'general'
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

          def retrieve_relevant(query: nil, limit: Helpers::Confidence.apollo_setting(:query, :retrieval_limit, default: 5), min_confidence: Helpers::GraphQuery.default_query_min_confidence, tags: nil, domain: nil, skip: false, **) # rubocop:disable Layout/LineLength
            return { status: :skipped } if skip

            return { success: false, error: 'apollo_data_not_available' } unless Helpers::DataModels.apollo_entry_available?

            query = normalize_text_input(query)
            log.debug("Apollo Knowledge.retrieve_relevant query_length=#{query.length} limit=#{limit} min_confidence=#{min_confidence} tags=#{Array(tags).size} domain=#{domain || 'nil'}") # rubocop:disable Layout/LineLength
            return { success: true, entries: [], count: 0 } if query.nil? || query.to_s.strip.empty?

            embedding = embed_text(query)
            sql = Helpers::GraphQuery.build_semantic_search_sql(
              limit: limit, min_confidence: min_confidence,
              statuses: %w[confirmed candidate], tags: tags, domain: domain
            )

            db = Helpers::DataModels.apollo_entry.db
            entries = db.fetch(sql, embedding: Sequel.lit("'[#{embedding.join(',')}]'::vector")).all
            entries = entries.reject { |e| e[:distance].respond_to?(:nan?) && e[:distance].nan? }

            entries.each do |entry|
              Helpers::DataModels.apollo_entry.where(id: entry[:id]).update(
                confidence: Helpers::Confidence.apply_retrieval_boost(confidence: entry[:confidence]),
                updated_at: Time.now
              )
            end

            formatted = entries.map do |entry|
              { id: entry[:id], content: entry[:content], content_type: entry[:content_type],
                confidence: entry[:confidence], distance: entry[:distance]&.to_f,
                tags: entry[:tags], source_agent: entry[:source_agent],
                knowledge_domain: entry[:knowledge_domain] }
            end

            log.info("Apollo Knowledge.retrieve_relevant results=#{formatted.size} limit=#{limit}")
            { success: true, entries: formatted, count: formatted.size }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.knowledge.retrieve_relevant')
            { success: false, error: e.message }
          end

          def prepare_mesh_export(target_domain:, min_confidence: Helpers::Confidence.apollo_setting(:query, :mesh_export_min_confidence, default: 0.5), limit: Helpers::Confidence.apollo_setting(:query, :mesh_export_limit, default: 100), **) # rubocop:disable Layout/LineLength
            unless defined?(Legion::Data) && Legion::Data.respond_to?(:connection) && Legion::Data.connection
              return { success: false, error: 'apollo_data_not_available' }
            end

            log.debug("Apollo Knowledge.prepare_mesh_export target_domain=#{target_domain} min_confidence=#{min_confidence} limit=#{limit}")
            conn = Legion::Data.connection
            allowed = allowed_domains_for(target_domain)

            dataset = conn[:apollo_entries]
                      .where(status: 'confirmed')
                      .where { confidence >= min_confidence }
                      .limit(limit)

            dataset = dataset.where(knowledge_domain: allowed) unless allowed == :all

            entries = dataset.all

            formatted = entries.map do |entry|
              { id: entry[:id], content: entry[:content], content_type: entry[:content_type],
                confidence: entry[:confidence], knowledge_domain: entry[:knowledge_domain],
                tags: entry[:tags], source_agent: entry[:source_agent] }
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

            # Redact attribution on confirmed entries (corroborated, retain knowledge)
            redacted = conn[:apollo_entries]
                       .where(source_agent: agent_id, status: 'confirmed')
                       .update(source_agent: 'redacted', source_provider: nil, source_channel: nil)

            { deleted: deleted, redacted: redacted, agent_id: agent_id }
              .tap { |result| log.info("Apollo Knowledge.handle_erasure_request deleted=#{result[:deleted]} redacted=#{result[:redacted]} agent_id=#{agent_id}") } # rubocop:disable Layout/LineLength
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.knowledge.handle_erasure_request')
            { deleted: 0, redacted: 0, error: e.message }
          end

          CONFLICT_CHECK_MAX_CHARS = 4000

          private

          def ingest_early_return_error(content:, content_type:, tags:)
            if content.strip.empty?
              safe_tags = Array(tags).map(&:to_s).map { |t| t.gsub(/[\r\n]+/, ' ') }
              log.warn('[apollo][handle_ingest] early-return: content is required ' \
                       "content_type=#{content_type} tags=#{safe_tags.inspect}")
              return { success: false, error: 'content is required' }
            end

            if content_type.nil?
              log.warn('[apollo][handle_ingest] early-return: content_type is required ' \
                       "content_length=#{content.to_s.length}")
              return { success: false, error: 'content_type is required' }
            end

            return nil if Helpers::DataModels.apollo_entry_available?

            log.warn('[apollo][handle_ingest] early-return: apollo_data_not_available ' \
                     "content_type=#{content_type}")
            { success: false, error: 'apollo_data_not_available' }
          end

          def normalize_content_type(raw)
            sym = raw.to_s.delete_prefix(':').gsub(%r{[/\s]}, '_').strip.downcase.to_sym
            sym = CONTENT_TYPE_ALIASES.fetch(sym, sym)
            Helpers::Confidence::CONTENT_TYPES.include?(sym) ? sym : :observation
          end

          def embed_text(text)
            text = normalize_text_input(text)
            log.debug("Apollo Knowledge.embed_text text_length=#{text.length}")
            result = Legion::LLM::Call::Embeddings.generate(text: text)
            vector = result.is_a?(Hash) ? result[:vector] : result
            if vector.is_a?(Array) && vector.any?
              log.debug("Apollo Knowledge.embed_text vector_dimensions=#{vector.length}")
              vector
            else
              log.warn('Apollo Knowledge.embed_text returned no vector; using zero-vector fallback')
              Array.new(1024, 0.0)
            end
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.knowledge.embed_text')
            Array.new(1024, 0.0)
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

          def active_duplicate_for_hash(hash)
            return nil unless hash

            existing = Helpers::DataModels.apollo_entry
                                          .where(content_hash: hash)
                                          .exclude(status: 'archived')
                                          .first
            existing&.update(confidence: [existing.confidence + Helpers::Confidence.retrieval_boost, 1.0].min)
            log.debug("Apollo Knowledge.active_duplicate_for_hash matched entry_id=#{existing.id}") if existing
            existing
          end

          def ingest_metadata(tags:, knowledge_domain:, source_agent:, source_provider:, source_channel:, submitted_by:, submitted_from:)
            tag_array = defined?(Helpers::TagNormalizer) ? Helpers::TagNormalizer.normalize_all(tags) : Array(tags)
            agent = truncate_for_column(source_agent, 50) || 'unknown'

            { tags:            tag_array,
              domain:          truncate_for_column(knowledge_domain || tag_array.first || 'general', 50),
              source_agent:    agent,
              source_provider: truncate_for_column(source_provider || derive_provider_from_agent(agent), 50),
              source_channel:  truncate_for_column(source_channel, 100),
              submitted_by:    truncate_for_column(submitted_by, 255),
              submitted_from:  truncate_for_column(submitted_from, 255) }
          end

          def create_candidate_entry(content:, content_type:, context:, metadata:, content_hash:, embedding:)
            new_entry = Helpers::DataModels.apollo_entry.create(
              content:          content,
              content_type:     content_type,
              confidence:       Helpers::Confidence.initial_confidence,
              source_agent:     metadata[:source_agent],
              source_provider:  metadata[:source_provider],
              source_channel:   metadata[:source_channel],
              source_context:   json_dump(context.is_a?(Hash) ? context : {}),
              tags:             Sequel.pg_array(metadata[:tags]),
              status:           'candidate',
              knowledge_domain: metadata[:domain],
              submitted_by:     metadata[:submitted_by],
              submitted_from:   metadata[:submitted_from],
              content_hash:     content_hash,
              embedding:        Sequel.lit("'[#{embedding.join(',')}]'::vector")
            )
            log.info("Apollo Knowledge.handle_ingest created entry_id=#{new_entry.id} status=candidate domain=#{metadata[:domain]} source_agent=#{metadata[:source_agent]}") # rubocop:disable Layout/LineLength
            new_entry.id
          end

          def browse_query?(query)
            query.to_s.strip.length < 3
          end

          def list_entries_chronologically(query:, limit:, status:, status_defaulted:, tags:, domain:)
            log.debug("Apollo Knowledge.list_entries_chronologically limit=#{limit} statuses=#{Array(status).join(',')} status_defaulted=#{status_defaulted} tags=#{Array(tags).size} domain=#{domain || 'nil'}") # rubocop:disable Layout/LineLength
            dataset = Helpers::DataModels.apollo_entry.exclude(status: 'archived')
            requested = Array(status).map(&:to_s).reject(&:empty?)
            dataset = dataset.where(status: requested) unless status_defaulted || requested.empty?
            dataset = dataset.where(Sequel.lit('tags && ?', Sequel.pg_array(Array(tags)))) if tags && !Array(tags).empty?
            dataset = dataset.where(knowledge_domain: domain) if domain && !domain.to_s.empty?

            entries = dataset.order(Sequel.desc(:created_at)).limit(limit).all.map do |entry|
              format_entry(entry.is_a?(Hash) ? entry : entry.values)
            end
            log.info("Apollo Knowledge.list_entries_chronologically results=#{entries.size}")
            { success: true, mode: :browse, query: query, entries: entries, count: entries.size }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.knowledge.list_entries_chronologically')
            { success: false, error: e.message }
          end

          def format_entry(entry)
            { id: entry[:id], content: entry[:content], content_type: entry[:content_type],
              confidence: entry[:confidence], distance: entry[:distance]&.to_f,
              tags: entry[:tags], source_agent: entry[:source_agent],
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

          def detect_contradictions(entry_id, embedding, content)
            return [] unless embedding && Helpers::DataModels.apollo_entry_available?

            sim_limit = Helpers::Confidence.apollo_setting(:contradiction, :similar_limit, default: 10)
            sim_threshold = Helpers::Confidence.apollo_setting(:contradiction, :similarity_threshold, default: 0.7)
            rel_weight = Helpers::Confidence.apollo_setting(:contradiction, :relation_weight, default: 0.8)

            db = Helpers::DataModels.apollo_entry.db
            log.debug("Apollo Knowledge.detect_contradictions entry_id=#{entry_id} similar_limit=#{sim_limit} threshold=#{sim_threshold}")
            similar = db.fetch(
              "SELECT id, content, embedding FROM apollo_entries WHERE id != :entry_id AND embedding IS NOT NULL ORDER BY embedding <=> :embedding LIMIT #{sim_limit}", # rubocop:disable Layout/LineLength
              entry_id:  entry_id,
              embedding: Sequel.lit("'[#{embedding.join(',')}]'::vector")
            ).all

            contradictions = []
            similar.each do |existing|
              existing_embedding = existing[:embedding]
              next unless existing_embedding

              sim = Helpers::Similarity.cosine_similarity(vec_a: embedding, vec_b: existing_embedding)
              next unless sim > sim_threshold
              next unless llm_detects_conflict?(content, existing[:content])

              Helpers::DataModels.apollo_relation.create(
                from_entry_id: entry_id, to_entry_id: existing[:id],
                relation_type: 'contradicts', source_agent: 'system:contradiction',
                weight: rel_weight
              )

              Helpers::DataModels.apollo_entry.where(id: [entry_id, existing[:id]]).update(status: 'disputed')
              contradictions << existing[:id]
            end
            log.info("Apollo Knowledge.detect_contradictions entry_id=#{entry_id} contradictions=#{contradictions.size}") if contradictions.any?
            contradictions
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.knowledge.detect_contradictions')
            []
          end

          def llm_detects_conflict?(content_a, content_b)
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

          def find_corroboration(embedding, content_type_sym, source_agent, source_channel = nil)
            scan_limit = Helpers::Confidence.apollo_setting(:corroboration, :scan_limit, default: 50)
            log.debug("Apollo Knowledge.find_corroboration content_type=#{content_type_sym} source_agent=#{source_agent} source_channel=#{source_channel || 'nil'} scan_limit=#{scan_limit}") # rubocop:disable Layout/LineLength
            existing = Helpers::DataModels.apollo_entry
                                          .where(content_type: content_type_sym)
                                          .exclude(embedding: nil)
                                          .limit(scan_limit)

            existing.each do |entry|
              next unless entry.embedding

              sim = Helpers::Similarity.cosine_similarity(vec_a: embedding, vec_b: entry.embedding)
              next unless Helpers::Similarity.above_corroboration_threshold?(similarity: sim)

              same_provider_wt = Helpers::Confidence.apollo_setting(:corroboration, :same_provider_weight, default: 0.5)
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
              Helpers::DataModels.apollo_relation.create(
                from_entry_id: entry.id,
                to_entry_id:   entry.id,
                relation_type: 'similar_to',
                source_agent:  source_agent,
                weight:        sim
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
                proficiency: Helpers::Confidence.apollo_setting(:expertise, :initial_proficiency, default: 0.0),
                entry_count: 1, last_active_at: Time.now
              )
            end
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
