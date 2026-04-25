# frozen_string_literal: true

require 'json'
require_relative '../helpers/confidence'

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

            if defined?(Legion::Data::Model::ApolloEntry)
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
            if defined?(Legion::Data::Model::ApolloEntry)
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
            return handle_traverse(entry_id: entry_id, depth: depth, relation_types: relation_types, **) if defined?(Legion::Data::Model::ApolloEntry)

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
            return { success: false, error: 'content is required' } if content.strip.empty?
            return { success: false, error: 'content_type is required' } if content_type.nil?
            return { success: false, error: 'apollo_data_not_available' } unless defined?(Legion::Data::Model::ApolloEntry)

            hash = content_hash || (defined?(Helpers::Writeback) ? Helpers::Writeback.content_hash(content) : nil)
            existing = active_duplicate_for_hash(hash)
            return { success: true, entry_id: existing.id, deduped: true } if existing

            embedding = embed_text(content)
            content_type_sym = content_type.to_s
            metadata = ingest_metadata(tags: tags, knowledge_domain: knowledge_domain, source_agent: source_agent,
                                       source_provider: source_provider, source_channel: source_channel,
                                       submitted_by: submitted_by, submitted_from: submitted_from)

            corroborated, existing_id = find_corroboration(
              embedding, content_type_sym, metadata[:source_agent], metadata[:source_channel]
            )

            unless corroborated
              new_entry = Legion::Data::Model::ApolloEntry.create(
                content:          content,
                content_type:     content_type_sym,
                confidence:       Helpers::Confidence.initial_confidence,
                source_agent:     metadata[:source_agent],
                source_provider:  metadata[:source_provider],
                source_channel:   metadata[:source_channel],
                source_context:   ::JSON.dump(context.is_a?(Hash) ? context : {}),
                tags:             Sequel.pg_array(metadata[:tags]),
                status:           'candidate',
                knowledge_domain: metadata[:domain],
                submitted_by:     metadata[:submitted_by],
                submitted_from:   metadata[:submitted_from],
                content_hash:     hash,
                embedding:        Sequel.lit("'[#{embedding.join(',')}]'::vector")
              )
              existing_id = new_entry.id
            end

            upsert_expertise(source_agent: metadata[:source_agent], domain: metadata[:domain])

            Legion::Data::Model::ApolloAccessLog.create(
              entry_id: existing_id, agent_id: metadata[:source_agent], action: 'ingest'
            )

            contradictions = detect_contradictions(existing_id, embedding, content)

            { success: true, entry_id: existing_id, status: corroborated ? 'corroborated' : 'candidate',
              corroborated: corroborated, contradictions: contradictions }
          rescue Sequel::Error => e
            log_sequel_error('handle_ingest', e)
            { success: false, error: e.message }
          end

          def handle_query(query:, limit: Helpers::GraphQuery.default_query_limit, min_confidence: Helpers::GraphQuery.default_query_min_confidence, status: UNSET, tags: nil, domain: nil, agent_id: 'unknown', **) # rubocop:disable Layout/LineLength
            return { success: false, error: 'apollo_data_not_available' } unless defined?(Legion::Data::Model::ApolloEntry)

            query = normalize_text_input(query)
            status_defaulted = status.equal?(UNSET)
            requested_status = status_defaulted ? DEFAULT_QUERY_STATUS : status
            if browse_query?(query)
              return list_entries_chronologically(query: query, limit: limit, status: requested_status,
                                                  status_defaulted: status_defaulted, tags: tags, domain: domain)
            end

            embedding = embed_text(query)
            sql = Helpers::GraphQuery.build_semantic_search_sql(
              limit: limit, min_confidence: min_confidence,
              statuses: Array(requested_status).map(&:to_s), tags: tags, domain: domain
            )

            db = Legion::Data::Model::ApolloEntry.db
            entries = db.fetch(sql, embedding: Sequel.lit("'[#{embedding.join(',')}]'::vector")).all

            entries = entries.reject { |e| e[:distance].respond_to?(:nan?) && e[:distance].nan? }

            entries.each do |entry|
              Legion::Data::Model::ApolloEntry.where(id: entry[:id]).update(
                access_count: Sequel.expr(:access_count) + 1,
                confidence:   Helpers::Confidence.apply_retrieval_boost(
                  confidence: entry[:confidence]
                ),
                updated_at:   Time.now
              )
            end

            if entries.any?
              Legion::Data::Model::ApolloAccessLog.create(
                entry_id: entries.first&.dig(:id), agent_id: agent_id, action: 'query'
              )
            end

            formatted = entries.map do |entry|
              { id: entry[:id], content: entry[:content], content_type: entry[:content_type],
                confidence: entry[:confidence], distance: entry[:distance]&.to_f,
                tags: entry[:tags], source_agent: entry[:source_agent],
                knowledge_domain: entry[:knowledge_domain] }
            end

            { success: true, entries: formatted, count: formatted.size }
          rescue Sequel::Error => e
            log_sequel_error('handle_query', e)
            { success: false, error: e.message }
          end

          def handle_traverse(entry_id:, depth: Helpers::GraphQuery.default_depth, relation_types: nil, agent_id: 'unknown', **)
            return { success: false, error: 'apollo_data_not_available' } unless defined?(Legion::Data::Model::ApolloEntry)

            # Whitelist relation_types to prevent SQL injection (they are string-interpolated in build_traversal_sql)
            if relation_types
              allowed = Helpers::Confidence::RELATION_TYPES
              relation_types = relation_types.select { |t| allowed.include?(t.to_s) }
            end

            sql = Helpers::GraphQuery.build_traversal_sql(depth: depth, relation_types: relation_types)
            db = Legion::Data::Model::ApolloEntry.db
            entries = db.fetch(sql, entry_id: entry_id).all

            if entries.any? && agent_id != 'unknown'
              Legion::Data::Model::ApolloAccessLog.create(
                entry_id: entry_id, agent_id: agent_id, action: 'query'
              )
            end

            formatted = entries.map do |entry|
              { id: entry[:id], content: entry[:content], content_type: entry[:content_type],
                confidence: entry[:confidence], tags: entry[:tags], source_agent: entry[:source_agent],
                depth: entry[:depth], activation: entry[:activation] }
            end

            { success: true, entries: formatted, count: formatted.size }
          rescue Sequel::Error => e
            log_sequel_error('handle_traverse', e)
            { success: false, error: e.message }
          end

          def redistribute_knowledge(agent_id:, min_confidence: Helpers::Confidence.apollo_setting(:query, :redistribute_min_confidence, default: 0.5), **)
            return { success: false, error: 'apollo_data_not_available' } unless defined?(Legion::Data::Model::ApolloEntry)

            entries = Legion::Data::Model::ApolloEntry
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
            log_sequel_error('redistribute_knowledge', e)
            { success: false, error: e.message }
          end

          def retrieve_relevant(query: nil, limit: Helpers::Confidence.apollo_setting(:query, :retrieval_limit, default: 5), min_confidence: Helpers::GraphQuery.default_query_min_confidence, tags: nil, domain: nil, skip: false, **) # rubocop:disable Layout/LineLength
            return { status: :skipped } if skip

            return { success: false, error: 'apollo_data_not_available' } unless defined?(Legion::Data::Model::ApolloEntry)

            query = normalize_text_input(query)
            return { success: true, entries: [], count: 0 } if query.nil? || query.to_s.strip.empty?

            embedding = embed_text(query)
            sql = Helpers::GraphQuery.build_semantic_search_sql(
              limit: limit, min_confidence: min_confidence,
              statuses: %w[confirmed candidate], tags: tags, domain: domain
            )

            db = Legion::Data::Model::ApolloEntry.db
            entries = db.fetch(sql, embedding: Sequel.lit("'[#{embedding.join(',')}]'::vector")).all
            entries = entries.reject { |e| e[:distance].respond_to?(:nan?) && e[:distance].nan? }

            entries.each do |entry|
              Legion::Data::Model::ApolloEntry.where(id: entry[:id]).update(
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

            { success: true, entries: formatted, count: formatted.size }
          rescue Sequel::Error => e
            log_sequel_error('retrieve_relevant', e)
            { success: false, error: e.message }
          end

          def prepare_mesh_export(target_domain:, min_confidence: Helpers::Confidence.apollo_setting(:query, :mesh_export_min_confidence, default: 0.5), limit: Helpers::Confidence.apollo_setting(:query, :mesh_export_limit, default: 100), **) # rubocop:disable Layout/LineLength
            unless defined?(Legion::Data) && Legion::Data.respond_to?(:connection) && Legion::Data.connection
              return { success: false, error: 'apollo_data_not_available' }
            end

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
          rescue Sequel::Error => e
            log_sequel_error('prepare_mesh_export', e)
            { success: false, error: e.message }
          end

          def handle_erasure_request(agent_id:, **)
            unless defined?(Legion::Data) && Legion::Data.respond_to?(:connection) && Legion::Data.connection
              return { deleted: 0, redacted: 0, error: 'apollo_data_not_available' }
            end

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
          rescue Sequel::Error => e
            log_sequel_error('handle_erasure_request', e)
            { deleted: 0, redacted: 0, error: e.message }
          end

          CONFLICT_CHECK_MAX_CHARS = 4000

          private

          def normalize_content_type(raw)
            sym = raw.to_s.delete_prefix(':').gsub(%r{[/\s]}, '_').strip.downcase.to_sym
            sym = CONTENT_TYPE_ALIASES.fetch(sym, sym)
            Helpers::Confidence::CONTENT_TYPES.include?(sym) ? sym : :observation
          end

          def embed_text(text)
            text = normalize_text_input(text)
            result = Legion::LLM::Embeddings.generate(text: text)
            vector = result.is_a?(Hash) ? result[:vector] : result
            vector.is_a?(Array) && vector.any? ? vector : Array.new(1024, 0.0)
          rescue StandardError => e
            log.warn("Apollo Knowledge.embed_text failed: #{e.message}")
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
            log.warn("Apollo Knowledge.normalize_text_input failed: #{e.message}")
            ''
          end

          def sanitize_for_postgres(value)
            return value unless value.is_a?(String)

            string = value.encoding == Encoding::UTF_8 ? value.dup : value.dup.force_encoding(Encoding::UTF_8)
            string = string.scrub('') unless string.valid_encoding?
            string.delete("\x00")
          end

          def truncate_for_column(value, max_length)
            return nil if value.nil?

            normalize_text_input(value)[0, max_length]
          end

          def active_duplicate_for_hash(hash)
            return nil unless hash

            existing = Legion::Data::Model::ApolloEntry
                       .where(content_hash: hash)
                       .exclude(status: 'archived')
                       .first
            existing&.update(confidence: [existing.confidence + Helpers::Confidence.retrieval_boost, 1.0].min)
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

          def browse_query?(query)
            query.to_s.strip.length < 3
          end

          def list_entries_chronologically(query:, limit:, status:, status_defaulted:, tags:, domain:)
            dataset = Legion::Data::Model::ApolloEntry.exclude(status: 'archived')
            requested = Array(status).map(&:to_s).reject(&:empty?)
            dataset = dataset.where(status: requested) unless status_defaulted || requested.empty?
            dataset = dataset.where(Sequel.lit('tags && ?', Sequel.pg_array(Array(tags)))) if tags && !Array(tags).empty?
            dataset = dataset.where(knowledge_domain: domain) if domain && !domain.to_s.empty?

            entries = dataset.order(Sequel.desc(:created_at)).limit(limit).all.map do |entry|
              format_entry(entry.is_a?(Hash) ? entry : entry.values)
            end
            { success: true, mode: :browse, query: query, entries: entries, count: entries.size }
          rescue Sequel::Error => e
            log_sequel_error('list_entries_chronologically', e)
            { success: false, error: e.message }
          end

          def format_entry(entry)
            { id: entry[:id], content: entry[:content], content_type: entry[:content_type],
              confidence: entry[:confidence], distance: entry[:distance]&.to_f,
              tags: entry[:tags], source_agent: entry[:source_agent],
              knowledge_domain: entry[:knowledge_domain] }
          end

          def log_sequel_error(context, error)
            log.error("Apollo Knowledge.#{context} Sequel error: #{error.class}: #{error.message}")
            Array(error.backtrace).first(10).each { |frame| log.error("  #{frame}") }
          end

          def allowed_domains_for(target_domain)
            rules = if defined?(Legion::Settings) && Legion::Settings.dig(:apollo, :domain_isolation)
                      Legion::Settings.dig(:apollo, :domain_isolation)
                    else
                      DOMAIN_ISOLATION
                    end

            allowed = rules[target_domain]
            return :all if allowed == :all || allowed.nil?

            Array(allowed)
          end

          def detect_contradictions(entry_id, embedding, content)
            return [] unless embedding && defined?(Legion::Data::Model::ApolloEntry)

            sim_limit = Helpers::Confidence.apollo_setting(:contradiction, :similar_limit, default: 10)
            sim_threshold = Helpers::Confidence.apollo_setting(:contradiction, :similarity_threshold, default: 0.7)
            rel_weight = Helpers::Confidence.apollo_setting(:contradiction, :relation_weight, default: 0.8)

            db = Legion::Data::Model::ApolloEntry.db
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

              Legion::Data::Model::ApolloRelation.create(
                from_entry_id: entry_id, to_entry_id: existing[:id],
                relation_type: 'contradicts', source_agent: 'system:contradiction',
                weight: rel_weight
              )

              Legion::Data::Model::ApolloEntry.where(id: [entry_id, existing[:id]]).update(status: 'disputed')
              contradictions << existing[:id]
            end
            contradictions
          rescue Sequel::Error => e
            log_sequel_error('detect_contradictions', e)
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
            log.warn("Apollo Knowledge.llm_detects_conflict? failed: #{e.message}")
            false
          end

          def find_corroboration(embedding, content_type_sym, source_agent, source_channel = nil)
            scan_limit = Helpers::Confidence.apollo_setting(:corroboration, :scan_limit, default: 50)
            existing = Legion::Data::Model::ApolloEntry
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
              Legion::Data::Model::ApolloRelation.create(
                from_entry_id: entry.id,
                to_entry_id:   entry.id,
                relation_type: 'similar_to',
                source_agent:  source_agent,
                weight:        sim
              )
              return [true, entry.id]
            end

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
            expertise = Legion::Data::Model::ApolloExpertise
                        .where(agent_id: source_agent, domain: domain).first
            if expertise
              expertise.update(entry_count: expertise.entry_count + 1, last_active_at: Time.now)
            else
              Legion::Data::Model::ApolloExpertise.create(
                agent_id: source_agent, domain: domain,
                proficiency: Helpers::Confidence.apollo_setting(:expertise, :initial_proficiency, default: 0.0),
                entry_count: 1, last_active_at: Time.now
              )
            end
          end

          include Legion::Extensions::Helpers::Lex if defined?(Legion::Extensions::Helpers::Lex)
        end
      end
    end
  end
end
