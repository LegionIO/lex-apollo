# frozen_string_literal: true

module Legion
  module Extensions
    module Apollo
      module Helpers
        module GraphQuery
          extend Legion::Settings::Helper

          SPREAD_FACTOR = 0.6
          DEFAULT_DEPTH = 2
          MIN_ACTIVATION = 0.1

          module_function

          def spread_factor  = settings[:graph][:spread_factor]
          def default_depth  = settings[:graph][:default_depth]
          def min_activation = settings[:graph][:min_activation]

          def default_query_limit          = settings[:query][:default_limit]
          def default_query_min_confidence = settings[:query][:default_min_confidence]

          def build_traversal_sql(relation_types: nil, requesting_principal_id: nil, **)
            type_filter = relation_types&.any? ? 'AND r.relation_type IN :relation_types' : ''
            visibility = if requesting_principal_id
                           "AND #{access_scope_sql(qualified: true, global_only: requesting_principal_id.zero?)}"
                         else
                           ''
                         end

            <<~SQL
              WITH RECURSIVE graph AS (
                SELECT e.id, e.content, e.content_type, e.confidence, e.tags, e.source_agent,
                       0 AS depth, 1.0::float AS activation
                FROM apollo_entries e
                WHERE e.id = :entry_id AND e.status != 'archived' #{visibility}

                UNION ALL

                SELECT e.id, e.content, e.content_type, e.confidence, e.tags, e.source_agent,
                       g.depth + 1,
                       (g.activation * :spread_factor * r.weight)::float
                FROM graph g
                JOIN apollo_relations r ON r.from_entry_id = g.id #{type_filter}
                JOIN apollo_entries e ON e.id = r.to_entry_id
                WHERE g.depth < :depth
                  AND g.activation * :spread_factor * r.weight > :min_activation
                  AND e.status != 'archived' #{visibility}
              )
              SELECT DISTINCT ON (id) id, content, content_type, confidence, tags, source_agent,
                     depth, activation
              FROM graph
              ORDER BY id, activation DESC
            SQL
          end

          def build_semantic_search_sql(statuses: nil, tags: nil, tag_match: :any, domain: nil,
                                        exclude_source_agents: [], requesting_principal_id: nil, **)
            conditions = ['e.confidence >= :min_confidence']
            conditions << 'e.status IN :statuses' if statuses&.any?
            tag_operator = tag_match.to_s == 'all' ? '@>' : '&&'
            conditions << "e.tags #{tag_operator} CAST(:tags AS text[])" if tags&.any?
            conditions << 'e.knowledge_domain = :domain' if domain
            conditions << '(e.source_agent IS NULL OR e.source_agent NOT IN :exclude_source_agents)' if exclude_source_agents&.any?

            conditions << access_scope_sql(qualified: true, global_only: requesting_principal_id.zero?) if requesting_principal_id

            where_clause = conditions.join(' AND ')

            <<~SQL
              SELECT e.id, e.content, e.content_type, e.confidence, e.tags, e.source_agent,
                     e.access_count, e.created_at, e.knowledge_domain,
                     (e.embedding <=> CAST(:embedding AS vector)) AS distance
              FROM apollo_entries e
              WHERE #{where_clause}
                AND e.embedding IS NOT NULL
              ORDER BY e.embedding <=> CAST(:embedding AS vector)
              LIMIT :limit
            SQL
          end

          def access_scope_sql(qualified: false, global_only: false, **)
            prefix = qualified ? 'e.' : ''
            return "#{prefix}access_scope = 'global'" if global_only

            <<~SQL
              (#{prefix}access_scope = 'global'
               OR (#{prefix}access_scope = 'private'
                   AND (#{prefix}identity_principal_id = :requesting_principal_id
                        OR #{prefix}identity_id IN (SELECT id FROM identities WHERE principal_id = :requesting_principal_id)))
               OR (#{prefix}access_scope = 'team'
                   AND EXISTS (
                     SELECT 1 FROM identity_group_memberships igm1
                     JOIN identity_group_memberships igm2 ON igm1.group_id = igm2.group_id
                     WHERE igm1.principal_id = :requesting_principal_id
                       AND igm2.principal_id = #{prefix}identity_principal_id
                   )))
            SQL
          end
        end
      end
    end
  end
end
