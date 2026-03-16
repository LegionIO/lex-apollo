# frozen_string_literal: true

module Legion
  module Extensions
    module Apollo
      module Helpers
        module GraphQuery
          SPREAD_FACTOR = 0.6
          DEFAULT_DEPTH = 2
          MIN_ACTIVATION = 0.1

          module_function

          def build_traversal_sql(depth: DEFAULT_DEPTH, relation_types: nil, min_activation: MIN_ACTIVATION, **)
            type_filter = if relation_types&.any?
                            types = relation_types.map { |t| "'#{t}'" }.join(', ')
                            "AND r.relation_type IN (#{types})"
                          else
                            ''
                          end

            <<~SQL
              WITH RECURSIVE graph AS (
                SELECT e.id, e.content, e.content_type, e.confidence, e.tags, e.source_agent,
                       0 AS depth, 1.0::float AS activation
                FROM apollo_entries e
                WHERE e.id = $entry_id

                UNION ALL

                SELECT e.id, e.content, e.content_type, e.confidence, e.tags, e.source_agent,
                       g.depth + 1,
                       (g.activation * #{SPREAD_FACTOR} * r.weight)::float
                FROM graph g
                JOIN apollo_relations r ON r.from_entry_id = g.id #{type_filter}
                JOIN apollo_entries e ON e.id = r.to_entry_id
                WHERE g.depth < #{depth}
                  AND g.activation * #{SPREAD_FACTOR} * r.weight > #{min_activation}
              )
              SELECT DISTINCT ON (id) id, content, content_type, confidence, tags, source_agent,
                     depth, activation
              FROM graph
              ORDER BY id, activation DESC
            SQL
          end

          def build_semantic_search_sql(limit: 10, min_confidence: 0.3, statuses: nil, tags: nil, **)
            conditions = ["e.confidence >= #{min_confidence}"]

            if statuses&.any?
              status_list = statuses.map { |s| "'#{s}'" }.join(', ')
              conditions << "e.status IN (#{status_list})"
            end

            if tags&.any?
              tag_list = tags.map { |t| "'#{t}'" }.join(', ')
              conditions << "e.tags && ARRAY[#{tag_list}]::text[]"
            end

            where_clause = conditions.join(' AND ')

            <<~SQL
              SELECT e.id, e.content, e.content_type, e.confidence, e.tags, e.source_agent,
                     e.access_count, e.created_at,
                     (e.embedding <=> $embedding) AS distance
              FROM apollo_entries e
              WHERE #{where_clause}
                AND e.embedding IS NOT NULL
              ORDER BY e.embedding <=> $embedding
              LIMIT #{limit}
            SQL
          end
        end
      end
    end
  end
end
