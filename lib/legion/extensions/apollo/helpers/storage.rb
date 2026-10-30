# frozen_string_literal: true

require 'sequel'
require 'sequel/extensions/pg_array'
require 'sequel/extensions/pg_json'
require 'legion/json'
require_relative 'embedding'
require_relative 'graph_query'
require_relative 'similarity'

module Legion
  module Extensions
    module Apollo
      module Helpers
        module Storage
          extend Legion::Logging::Helper

          module_function

          def serialize_tags(db:, tags:, **)
            case db.database_type
            when :postgres then Sequel.pg_array(Array(tags).map(&:to_s), :text)
            when :sqlite then Legion::JSON.dump(Array(tags).map(&:to_s))
            else raise ArgumentError, "unsupported Apollo adapter: #{db.database_type}"
            end
          end

          def serialize_embedding(db:, vector:, **)
            return nil if vector.nil?

            case db.database_type
            when :postgres then "[#{vector.join(',')}]"
            when :sqlite then Legion::JSON.dump(vector)
            else raise ArgumentError, "unsupported Apollo adapter: #{db.database_type}"
            end
          end

          def serialize_provenance(db:, provenance:, **)
            return nil if provenance.nil?

            case db.database_type
            when :postgres then Sequel.pg_jsonb(provenance)
            when :sqlite then Legion::JSON.dump(provenance)
            else raise ArgumentError, "unsupported Apollo adapter: #{db.database_type}"
            end
          end

          def deserialize_tags(tags:, **)
            return [] if tags.nil? || tags == '{}'
            return tags.to_a if tags.respond_to?(:to_ary)

            parsed = Legion::JSON.load(tags)
            raise ArgumentError, 'stored Apollo tags must be an array' unless parsed.is_a?(Array)

            parsed
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.storage.deserialize_tags')
            []
          end

          def filter_tags(dataset:, tags:, tag_match: :any, **)
            return dataset if tags.nil? || tags.empty?

            values = serialize_tags(db: dataset.db, tags: tags)
            if dataset.db.database_type == :postgres
              operator = tag_match.to_s == 'all' ? '@>' : '&&'
              return dataset.where(Sequel.lit("tags #{operator} CAST(? AS text[])", values))
            end

            stored = "CASE WHEN json_valid(tags) THEN tags ELSE '[]' END"
            predicate = if tag_match.to_s == 'all'
                          'NOT EXISTS (SELECT 1 FROM json_each(?) wanted WHERE NOT EXISTS ' \
                            "(SELECT 1 FROM json_each(#{stored}) stored WHERE stored.value = wanted.value))"
                        else
                          "EXISTS (SELECT 1 FROM json_each(#{stored}) stored " \
                            'WHERE stored.value IN (SELECT value FROM json_each(?)))'
                        end
            dataset.where(Sequel.lit(predicate, values))
          end

          def semantic_search(db:, embedding:, provenance:, limit: Legion::Extensions::Apollo::Helpers::GraphQuery.default_query_limit, **filters)
            provenance = Legion::Extensions::Apollo::Helpers::Embedding.parse_provenance(value: provenance)
            unless Legion::Extensions::Apollo::Helpers::Embedding.valid?(vector: embedding, provenance: provenance)
              raise ArgumentError, 'Apollo semantic search requires a valid embedding and provenance'
            end
            raise ArgumentError, "unsupported Apollo adapter: #{db.database_type}" unless %i[postgres sqlite].include?(db.database_type)
            raise ArgumentError, 'Apollo search limit must be a positive integer' unless limit.is_a?(Integer) && limit.positive?

            options = { adapter: db.database_type, limit: limit,
                        min_confidence: filters.fetch(:min_confidence) { Legion::Extensions::Apollo::Helpers::GraphQuery.default_query_min_confidence },
                        statuses: filters.fetch(:statuses) { %w[confirmed candidate] },
                        tags: filters[:tags], tag_match: filters.fetch(:tag_match, :any), domain: filters[:domain],
                        exclude_source_agents: filters.fetch(:exclude_source_agents) { [] },
                        requesting_principal_id: filters[:requesting_principal_id],
                        access_scope: filters[:access_scope]&.to_s, identity_principal_id: filters[:identity_principal_id],
                        embedding_space_id: provenance[:space_id], embedding_dimensions: provenance[:dimensions],
                        embedding_identity_source: provenance[:identity_source] }
            sql = Legion::Extensions::Apollo::Helpers::GraphQuery.build_semantic_search_sql(**options)
            %i[statuses tags exclude_source_agents].each do |key|
              options[key] = serialize_tags(db: db, tags: options[key])
            end
            comparison = provenance.reject { |key, _| key == :task || (key == :instance && provenance[:identity_source] == 'revision') }
            options[:embedding_provenance] = serialize_provenance(db: db, provenance: comparison)
            options[:embedding] = serialize_embedding(db: db, vector: embedding)
            candidates = db.fetch(sql, options)
            return candidates.all.map { |row| row.merge(tags: deserialize_tags(tags: row[:tags])) } if db.database_type == :postgres

            sqlite_top_matches(candidates: candidates, embedding: embedding, provenance: provenance, limit: limit)
          end

          def sqlite_top_matches(candidates:, embedding:, provenance:, limit:, **)
            matches = []
            candidates.each do |row|
              stored_provenance = Legion::Extensions::Apollo::Helpers::Embedding.parse_provenance(value: row[:embedding_provenance])
              next unless Legion::Extensions::Apollo::Helpers::Embedding.compatible?(left: provenance, right: stored_provenance)

              vector = Legion::Extensions::Apollo::Helpers::Similarity.parse_vector(vector: row[:embedding])
              next unless Legion::Extensions::Apollo::Helpers::Embedding.valid?(vector: vector, provenance: stored_provenance, task: :document)

              similarity = Legion::Extensions::Apollo::Helpers::Similarity.cosine_similarity(vec_a: embedding, vec_b: vector)
              row.delete(:embedding)
              row.delete(:embedding_provenance)
              row[:distance] = 1.0 - similarity.clamp(-1.0, 1.0)
              row[:tags] = deserialize_tags(tags: row[:tags])
              index = matches.bsearch_index do |match|
                ([match[:distance], match[:id]] <=> [row[:distance], row[:id]]) >= 0
              end || matches.length
              next if index >= limit

              matches.insert(index, row)
              matches.pop if matches.length > limit
            end
            matches
          end
        end
      end
    end
  end
end
