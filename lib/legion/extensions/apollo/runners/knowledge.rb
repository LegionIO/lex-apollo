# frozen_string_literal: true

require 'json'
require_relative '../helpers/confidence'
require_relative '../helpers/embedding'

module Legion
  module Extensions
    module Apollo
      module Runners
        module Knowledge
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

          def handle_ingest(content:, content_type:, tags: [], source_agent: 'unknown', context: {}, **)
            return { success: false, error: 'apollo_data_not_available' } unless defined?(Legion::Data::Model::ApolloEntry)

            embedding = Helpers::Embedding.generate(text: content)
            content_type_sym = content_type.to_s
            tag_array = Array(tags)

            corroborated, existing_id = find_corroboration(embedding, content_type_sym, source_agent)

            unless corroborated
              new_entry = Legion::Data::Model::ApolloEntry.create(
                content:        content,
                content_type:   content_type_sym,
                confidence:     Helpers::Confidence::INITIAL_CONFIDENCE,
                source_agent:   source_agent,
                source_context: ::JSON.dump(context.is_a?(Hash) ? context : {}),
                tags:           Sequel.pg_array(tag_array),
                status:         'candidate',
                embedding:      Sequel.lit("'[#{embedding.join(',')}]'::vector")
              )
              existing_id = new_entry.id
            end

            upsert_expertise(source_agent: source_agent, domain: tag_array.first || 'general')

            Legion::Data::Model::ApolloAccessLog.create(
              entry_id: existing_id, agent_id: source_agent, action: 'ingest'
            )

            { success: true, entry_id: existing_id, status: corroborated ? 'corroborated' : 'candidate',
              corroborated: corroborated }
          rescue Sequel::Error => e
            { success: false, error: e.message }
          end

          def handle_query(query:, limit: 10, min_confidence: 0.3, status: [:confirmed], tags: nil, agent_id: 'unknown', **) # rubocop:disable Metrics/ParameterLists
            return { success: false, error: 'apollo_data_not_available' } unless defined?(Legion::Data::Model::ApolloEntry)

            embedding = Helpers::Embedding.generate(text: query)
            sql = Helpers::GraphQuery.build_semantic_search_sql(
              limit: limit, min_confidence: min_confidence,
              statuses: Array(status).map(&:to_s), tags: tags
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
                tags: entry[:tags], source_agent: entry[:source_agent] }
            end

            { success: true, entries: formatted, count: formatted.size }
          rescue Sequel::Error => e
            { success: false, error: e.message }
          end

          def retrieve_relevant(query: nil, limit: 5, min_confidence: 0.3, tags: nil, skip: false, **)
            return { status: :skipped } if skip

            return { success: false, error: 'apollo_data_not_available' } unless defined?(Legion::Data::Model::ApolloEntry)

            return { success: true, entries: [], count: 0 } if query.nil? || query.to_s.strip.empty?

            embedding = Helpers::Embedding.generate(text: query.to_s)
            sql = Helpers::GraphQuery.build_semantic_search_sql(
              limit: limit, min_confidence: min_confidence,
              statuses: ['confirmed'], tags: tags
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
                tags: entry[:tags], source_agent: entry[:source_agent] }
            end

            { success: true, entries: formatted, count: formatted.size }
          rescue Sequel::Error => e
            { success: false, error: e.message }
          end

          private

          def find_corroboration(embedding, content_type_sym, source_agent)
            existing = Legion::Data::Model::ApolloEntry
                       .where(content_type: content_type_sym)
                       .exclude(embedding: nil)
                       .limit(50)

            existing.each do |entry|
              next unless entry.embedding

              sim = Helpers::Similarity.cosine_similarity(vec_a: embedding, vec_b: entry.embedding)
              next unless Helpers::Similarity.above_corroboration_threshold?(similarity: sim)

              entry.update(
                confidence: Helpers::Confidence.apply_corroboration_boost(confidence: entry.confidence),
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
