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
                       0 AS depth, CAST(1.0 AS double precision) AS activation
                FROM apollo_entries e
                WHERE e.id = :entry_id AND e.status != 'archived' #{visibility}

                UNION ALL

                SELECT e.id, e.content, e.content_type, e.confidence, e.tags, e.source_agent,
                       g.depth + 1,
                       CAST(g.activation * :spread_factor * r.weight AS double precision)
                FROM graph g
                JOIN apollo_relations r ON r.from_entry_id = g.id #{type_filter}
                JOIN apollo_entries e ON e.id = r.to_entry_id
                WHERE g.depth < :depth
                  AND g.activation * :spread_factor * r.weight > :min_activation
                  AND e.status != 'archived' #{visibility}
              ), ranked AS (
                SELECT graph.*,
                       ROW_NUMBER() OVER (PARTITION BY id ORDER BY activation DESC, depth ASC) AS activation_rank
                FROM graph
              )
              SELECT id, content, content_type, confidence, tags, source_agent, depth, activation
              FROM ranked
              WHERE activation_rank = 1
              ORDER BY id
            SQL
          end

          def build_semantic_search_sql(adapter: :postgres, **filters)
            raise ArgumentError, "unsupported Apollo adapter: #{adapter}" unless %i[postgres sqlite].include?(adapter)

            conditions = adapter == :postgres ? semantic_postgres_conditions(**filters) : semantic_sqlite_conditions(**filters)
            conditions.push('e.confidence >= :min_confidence', 'e.embedding IS NOT NULL')
            conditions << 'e.embedding_space_id = :embedding_space_id' if filters[:embedding_space_id]
            conditions << 'e.embedding_dimensions = :embedding_dimensions' if filters[:embedding_dimensions]
            conditions << 'e.knowledge_domain = :domain' if filters[:domain]
            principal = filters[:requesting_principal_id]
            conditions << access_scope_sql(qualified: true, global_only: principal.zero?) if principal
            if filters[:access_scope]
              conditions << 'e.access_scope = :access_scope'
              if filters[:access_scope].to_s != 'global'
                conditions << if filters[:identity_principal_id].nil?
                                'e.identity_principal_id IS NULL'
                              else
                                'e.identity_principal_id = :identity_principal_id'
                              end
              end
            end
            columns = 'e.id, e.content, e.content_type, e.confidence, e.tags, e.source_agent, ' \
                      'e.access_count, e.created_at, e.knowledge_domain, e.access_scope, e.identity_principal_id'
            where_clause = conditions.join(' AND ')

            return "SELECT #{columns}, e.embedding, e.embedding_provenance FROM apollo_entries e WHERE #{where_clause}" if adapter == :sqlite

            # Materialize the compatible space before pgvector evaluates a distance.
            <<~SQL
              WITH compatible AS MATERIALIZED (
                SELECT #{columns}, e.embedding
                FROM apollo_entries e
                WHERE #{where_clause}
              )
              SELECT id, content, content_type, confidence, tags, source_agent,
                     access_count, created_at, knowledge_domain, access_scope, identity_principal_id,
                     (embedding <=> CAST(:embedding AS vector)) AS distance
              FROM compatible
              ORDER BY distance, id
              LIMIT :limit
            SQL
          end

          def semantic_postgres_conditions(embedding_dimensions: nil, embedding_identity_source: nil,
                                           statuses: nil, tags: nil, tag_match: :any, exclude_source_agents: [], **)
            conditions = []
            conditions << 'vector_dims(e.embedding) = :embedding_dimensions' if embedding_dimensions
            if embedding_identity_source
              instance_filter = embedding_identity_source == 'revision' ? " - 'instance'" : ''
              conditions << "(e.embedding_provenance - 'task'#{instance_filter}) = CAST(:embedding_provenance AS jsonb)"
              conditions << "e.embedding_provenance->>'task' = 'document'"
              conditions << "jsonb_typeof(e.embedding_provenance->'instance') = 'string'"
              conditions << "length(trim(e.embedding_provenance->>'instance')) > 0"
              conditions << 'vector_norm(e.embedding) > 0'
            end
            conditions << 'e.status = ANY(CAST(:statuses AS text[]))' if statuses&.any?
            conditions << "e.tags #{tag_match.to_s == 'all' ? '@>' : '&&'} CAST(:tags AS text[])" if tags&.any?
            conditions << '(e.source_agent IS NULL OR NOT (e.source_agent = ANY(CAST(:exclude_source_agents AS text[]))))' if exclude_source_agents&.any?
            conditions
          end
          private_class_method :semantic_postgres_conditions

          def semantic_sqlite_conditions(statuses: nil, tags: nil, tag_match: :any, exclude_source_agents: [], **)
            conditions = []
            conditions << 'e.status IN (SELECT value FROM json_each(:statuses))' if statuses&.any?
            if tags&.any?
              tag_values = "CASE WHEN json_valid(e.tags) THEN e.tags ELSE '[]' END"
              conditions << if tag_match.to_s == 'all'
                              'NOT EXISTS (SELECT 1 FROM json_each(:tags) wanted WHERE NOT EXISTS ' \
                                "(SELECT 1 FROM json_each(#{tag_values}) stored WHERE stored.value = wanted.value))"
                            else
                              "EXISTS (SELECT 1 FROM json_each(#{tag_values}) stored " \
                                'WHERE stored.value IN (SELECT value FROM json_each(:tags)))'
                            end
            end
            if exclude_source_agents&.any?
              conditions << '(e.source_agent IS NULL OR e.source_agent NOT IN (SELECT value FROM json_each(:exclude_source_agents)))'
            end
            conditions
          end
          private_class_method :semantic_sqlite_conditions

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
