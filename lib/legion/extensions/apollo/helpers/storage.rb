# frozen_string_literal: true

require 'sequel'
require 'sequel/extensions/pg_array'
require 'sequel/extensions/pg_json'
require 'legion/json'

module Legion
  module Extensions
    module Apollo
      module Helpers
        module Storage
          private

          def storage_serialize_tags(db:, tags:, **)
            case db.database_type
            when :postgres then Sequel.pg_array(Array(tags).map(&:to_s), :text)
            when :sqlite then Legion::JSON.dump(Array(tags).map(&:to_s))
            else raise ArgumentError, "unsupported Apollo adapter: #{db.database_type}"
            end
          end

          def storage_serialize_embedding(db:, vector:, **)
            return nil if vector.nil?

            case db.database_type
            when :postgres then "[#{vector.join(',')}]"
            when :sqlite then Legion::JSON.dump(vector)
            else raise ArgumentError, "unsupported Apollo adapter: #{db.database_type}"
            end
          end

          def storage_serialize_provenance(db:, provenance:, **)
            return nil if provenance.nil?

            case db.database_type
            when :postgres then Sequel.pg_jsonb(provenance)
            when :sqlite then Legion::JSON.dump(provenance)
            else raise ArgumentError, "unsupported Apollo adapter: #{db.database_type}"
            end
          end

          def storage_deserialize_tags(tags:, **)
            return [] if tags.nil? || tags == '{}'
            return tags.to_a if tags.respond_to?(:to_ary)

            parsed = Legion::JSON.load(tags)
            raise ArgumentError, 'stored Apollo tags must be an array' unless parsed.is_a?(Array)

            parsed
          end

          def storage_filter_tags(dataset:, tags:, tag_match: :any, **)
            return dataset if tags.nil? || tags.empty?

            values = storage_serialize_tags(db: dataset.db, tags: tags)
            if dataset.db.database_type == :postgres
              operator = tag_match.to_s == 'all' ? '@>' : '&&'
              return dataset.where(Sequel.lit("tags #{operator} CAST(? AS text[])", values))
            end

            predicate = if tag_match.to_s == 'all'
                          'NOT EXISTS (SELECT 1 FROM json_each(?) wanted WHERE NOT EXISTS ' \
                            '(SELECT 1 FROM json_each(tags) stored WHERE stored.value = wanted.value))'
                        else
                          'EXISTS (SELECT 1 FROM json_each(tags) stored ' \
                            'WHERE stored.value IN (SELECT value FROM json_each(?)))'
                        end
            dataset.where(Sequel.lit(predicate, values))
          end
        end
      end
    end
  end
end
