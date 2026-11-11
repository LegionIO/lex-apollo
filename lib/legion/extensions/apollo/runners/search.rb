# frozen_string_literal: true

require 'legion/settings/helper'
require 'legion/logging/helper'
require 'legion/extensions/apollo/helpers/embedding'
require 'legion/extensions/apollo/helpers/graph_query'
require 'legion/extensions/apollo/helpers/similarity'
require 'legion/extensions/apollo/helpers/storage'

module Legion
  module Extensions
    module Apollo
      module Runners
        module Search
          include Legion::Settings::Helper
          include Legion::Logging::Helper
          extend Legion::Extensions::Apollo::Helpers::Embedding
          extend Legion::Extensions::Apollo::Helpers::GraphQuery
          extend Legion::Extensions::Apollo::Helpers::Similarity
          extend Legion::Extensions::Apollo::Helpers::Storage
          extend self

          def semantic_search(db:, embedding:, provenance:, limit: settings[:query][:default_limit], **filters)
            provenance = embedding_parse_provenance(value: provenance)
            unless embedding_valid?(vector: embedding, provenance: provenance)
              raise ArgumentError, 'Apollo semantic search requires a valid embedding and provenance'
            end
            raise ArgumentError, "unsupported Apollo adapter: #{db.database_type}" unless %i[postgres sqlite].include?(db.database_type)
            raise ArgumentError, 'Apollo search limit must be a positive integer' unless limit.is_a?(Integer) && limit.positive?

            options = {
              adapter: db.database_type, limit: limit,
              min_confidence: filters.fetch(:min_confidence) { settings[:query][:default_min_confidence] },
              statuses: filters.fetch(:statuses) { %w[confirmed candidate] },
              tags: filters[:tags], tag_match: filters.fetch(:tag_match, :any), domain: filters[:domain],
              exclude_source_agents: filters.fetch(:exclude_source_agents) { [] },
              requesting_principal_id: filters[:requesting_principal_id],
              access_scope: filters[:access_scope]&.to_s, identity_principal_id: filters[:identity_principal_id],
              embedding_space_id: provenance[:space_id], embedding_dimensions: provenance[:dimensions],
              embedding_identity_source: provenance[:identity_source]
            }
            sql = graph_build_semantic_search_sql(**options)
            %i[statuses tags exclude_source_agents].each do |key|
              options[key] = storage_serialize_tags(db: db, tags: options[key])
            end
            comparison = provenance.reject { |key, _| key == :task || (key == :instance && provenance[:identity_source] == 'revision') }
            options[:embedding_provenance] = storage_serialize_provenance(db: db, provenance: comparison)
            options[:embedding] = storage_serialize_embedding(db: db, vector: embedding)
            candidates = db.fetch(sql, options)
            entries = if db.database_type == :postgres
                        candidates.all.map { |row| row.merge(tags: storage_deserialize_tags(tags: row[:tags])) }
                      else
                        search_sqlite_top_matches(candidates: candidates, embedding: embedding, provenance: provenance, limit: limit)
                      end
            { success: true, entries: entries, count: entries.size }
          end

          private

          def search_sqlite_top_matches(candidates:, embedding:, provenance:, limit:)
            matches = []
            candidates.each do |row|
              stored_provenance = embedding_parse_provenance(value: row[:embedding_provenance])
              next unless embedding_compatible?(left: provenance, right: stored_provenance)

              vector = similarity_parse_vector(vector: row[:embedding])
              next unless embedding_valid?(vector: vector, provenance: stored_provenance, task: :document)

              similarity = similarity_cosine(vec_a: embedding, vec_b: vector)
              row.delete(:embedding)
              row.delete(:embedding_provenance)
              row[:distance] = 1.0 - similarity.clamp(-1.0, 1.0)
              row[:tags] = storage_deserialize_tags(tags: row[:tags])
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
