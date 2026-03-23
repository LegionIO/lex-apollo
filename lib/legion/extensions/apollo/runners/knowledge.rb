# frozen_string_literal: true

require 'json'
require_relative '../helpers/confidence'
require_relative '../helpers/embedding'

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

          def store_knowledge(content:, content_type:, tags: [], source_agent: nil, context: {}, **)
            content_type = content_type.to_sym
            unless Helpers::Confidence::CONTENT_TYPES.include?(content_type)
              raise ArgumentError, "invalid content_type: #{content_type}. Must be one of #{Helpers::Confidence::CONTENT_TYPES}"
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

          def query_knowledge(query:, limit: 10, min_confidence: 0.3, status: [:confirmed], tags: nil, **)
            {
              action:         :query,
              query:          query,
              limit:          limit,
              min_confidence: min_confidence,
              status:         Array(status),
              tags:           tags
            }
          end

          def related_entries(entry_id:, relation_types: nil, depth: 2, **)
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

          def handle_ingest(content:, content_type:, tags: [], source_agent: 'unknown', source_provider: nil, source_channel: nil, knowledge_domain: nil, context: {}, **) # rubocop:disable Metrics/ParameterLists, Layout/LineLength
            return { success: false, error: 'apollo_data_not_available' } unless defined?(Legion::Data::Model::ApolloEntry)

            embedding = Helpers::Embedding.generate(text: content)
            content_type_sym = content_type.to_s
            tag_array = Array(tags)
            domain = knowledge_domain || tag_array.first || 'general'

            corroborated, existing_id = find_corroboration(embedding, content_type_sym, source_agent, source_channel)

            unless corroborated
              new_entry = Legion::Data::Model::ApolloEntry.create(
                content:          content,
                content_type:     content_type_sym,
                confidence:       Helpers::Confidence::INITIAL_CONFIDENCE,
                source_agent:     source_agent,
                source_provider:  source_provider || derive_provider_from_agent(source_agent),
                source_channel:   source_channel,
                source_context:   ::JSON.dump(context.is_a?(Hash) ? context : {}),
                tags:             Sequel.pg_array(tag_array),
                status:           'candidate',
                knowledge_domain: domain,
                embedding:        Sequel.lit("'[#{embedding.join(',')}]'::vector")
              )
              existing_id = new_entry.id
            end

            upsert_expertise(source_agent: source_agent, domain: domain)

            Legion::Data::Model::ApolloAccessLog.create(
              entry_id: existing_id, agent_id: source_agent, action: 'ingest'
            )

            contradictions = detect_contradictions(existing_id, embedding, content)

            { success: true, entry_id: existing_id, status: corroborated ? 'corroborated' : 'candidate',
              corroborated: corroborated, contradictions: contradictions }
          rescue Sequel::Error => e
            { success: false, error: e.message }
          end

          def handle_query(query:, limit: 10, min_confidence: 0.3, status: [:confirmed], tags: nil, domain: nil, agent_id: 'unknown', **) # rubocop:disable Metrics/ParameterLists
            return { success: false, error: 'apollo_data_not_available' } unless defined?(Legion::Data::Model::ApolloEntry)

            embedding = Helpers::Embedding.generate(text: query)
            sql = Helpers::GraphQuery.build_semantic_search_sql(
              limit: limit, min_confidence: min_confidence,
              statuses: Array(status).map(&:to_s), tags: tags, domain: domain
            )

            db = Legion::Data::Model::ApolloEntry.db
            entries = db.fetch(sql, embedding: Sequel.lit("'[#{embedding.join(',')}]'::vector")).all

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
                confidence: entry[:confidence], distance: entry[:distance],
                tags: entry[:tags], source_agent: entry[:source_agent],
                knowledge_domain: entry[:knowledge_domain] }
            end

            { success: true, entries: formatted, count: formatted.size }
          rescue Sequel::Error => e
            { success: false, error: e.message }
          end

          def redistribute_knowledge(agent_id:, min_confidence: 0.5, **)
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

            Legion::Logging.info("[apollo] redistributed #{redistributed} entries from departing agent=#{agent_id}") if defined?(Legion::Logging)
            { success: true, redistributed: redistributed, agent_id: agent_id }
          rescue Sequel::Error => e
            { success: false, error: e.message }
          end

          def retrieve_relevant(query: nil, limit: 5, min_confidence: 0.3, tags: nil, domain: nil, skip: false, **) # rubocop:disable Metrics/ParameterLists
            return { status: :skipped } if skip

            return { success: false, error: 'apollo_data_not_available' } unless defined?(Legion::Data::Model::ApolloEntry)

            return { success: true, entries: [], count: 0 } if query.nil? || query.to_s.strip.empty?

            embedding = Helpers::Embedding.generate(text: query.to_s)
            sql = Helpers::GraphQuery.build_semantic_search_sql(
              limit: limit, min_confidence: min_confidence,
              statuses: ['confirmed'], tags: tags, domain: domain
            )

            db = Legion::Data::Model::ApolloEntry.db
            entries = db.fetch(sql, embedding: Sequel.lit("'[#{embedding.join(',')}]'::vector")).all

            entries.each do |entry|
              Legion::Data::Model::ApolloEntry.where(id: entry[:id]).update(
                confidence: Helpers::Confidence.apply_retrieval_boost(confidence: entry[:confidence]),
                updated_at: Time.now
              )
            end

            formatted = entries.map do |entry|
              { id: entry[:id], content: entry[:content], content_type: entry[:content_type],
                confidence: entry[:confidence], distance: entry[:distance],
                tags: entry[:tags], source_agent: entry[:source_agent],
                knowledge_domain: entry[:knowledge_domain] }
            end

            { success: true, entries: formatted, count: formatted.size }
          rescue Sequel::Error => e
            { success: false, error: e.message }
          end

          def prepare_mesh_export(target_domain:, min_confidence: 0.5, limit: 100, **)
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
            { deleted: 0, redacted: 0, error: e.message }
          end

          private

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

            similar = Legion::Data::Model::ApolloEntry
                      .exclude(id: entry_id)
                      .exclude(embedding: nil)
                      .limit(10).all

            contradictions = []
            similar.each do |existing|
              sim = Helpers::Similarity.cosine_similarity(vec_a: embedding, vec_b: existing.embedding)
              next unless sim > 0.7
              next unless llm_detects_conflict?(content, existing.content)

              Legion::Data::Model::ApolloRelation.create(
                from_entry_id: entry_id, to_entry_id: existing.id,
                relation_type: 'contradicts', source_agent: 'system:contradiction',
                weight: 0.8
              )

              Legion::Data::Model::ApolloEntry.where(id: [entry_id, existing.id]).update(status: 'disputed')
              contradictions << existing.id
            end
            contradictions
          rescue Sequel::Error
            []
          end

          def llm_detects_conflict?(content_a, content_b)
            return false unless defined?(Legion::LLM) && Legion::LLM.respond_to?(:structured)

            result = Legion::LLM.structured(
              messages: [
                { role: 'system', content: 'Do these two statements contradict each other? Return JSON.' },
                { role: 'user', content: "A: #{content_a}\n\nB: #{content_b}" }
              ],
              schema:   { type: 'object', properties: { contradicts: { type: 'boolean' } } }
            )
            result[:data]&.dig(:contradicts) == true
          rescue StandardError
            false
          end

          def find_corroboration(embedding, content_type_sym, source_agent, source_channel = nil)
            existing = Legion::Data::Model::ApolloEntry
                       .where(content_type: content_type_sym)
                       .exclude(embedding: nil)
                       .limit(50)

            existing.each do |entry|
              next unless entry.embedding

              sim = Helpers::Similarity.cosine_similarity(vec_a: embedding, vec_b: entry.embedding)
              next unless Helpers::Similarity.above_corroboration_threshold?(similarity: sim)

              weight = same_source_provider?(source_agent, entry) ? 0.5 : 1.0

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
                agent_id: source_agent, domain: domain, proficiency: 0.0,
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
