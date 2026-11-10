# frozen_string_literal: true

require 'legion/json'
require 'sequel'
require 'sequel/extensions/pg_json'

module Legion
  module Extensions
    module Apollo
      module Helpers
        module Embedding
          class Error < StandardError; end
          SPACE_FIELDS = %i[space_id provider model model_revision identity_source dimensions prefixes normalization].freeze

          private

          def embedding_parse_provenance(value:, **)
            return nil if value.nil?

            value = Legion::JSON.load(value) if value.is_a?(String)
            value = value.to_h if value.is_a?(Sequel::Postgres::JSONHash) || value.is_a?(Sequel::Postgres::JSONBHash)
            return nil unless value.is_a?(Hash)

            value = value.transform_keys { |key| key.is_a?(String) ? key.to_sym : key }
            if value[:prefixes].is_a?(Hash)
              value[:prefixes] = value[:prefixes].transform_keys { |key| key.is_a?(String) ? key.to_sym : key }
            end
            value
          rescue Legion::JSON::ParseError => e
            handle_exception(e, level: :warn, operation: 'apollo.embedding.parse_provenance')
            nil
          end

          def embedding_valid?(vector:, provenance:, task: nil, **)
            return false unless vector.is_a?(Array) && !vector.empty?
            return false unless vector.all? { |value| value.is_a?(Numeric) && value.real? && value.finite? }
            return false unless vector.any? { |value| !value.zero? }

            parsed = embedding_parse_provenance(value: provenance)
            embedding_provenance_valid?(provenance: parsed, task: task) && parsed[:dimensions] == vector.length
          end

          def embedding_compatible?(left:, right:, **)
            left = embedding_parse_provenance(value: left)
            right = embedding_parse_provenance(value: right)
            return false unless embedding_provenance_valid?(provenance: left) && embedding_provenance_valid?(provenance: right)
            return false unless SPACE_FIELDS.all? { |key| left[key] == right[key] }

            left[:identity_source] == 'revision' || left[:instance] == right[:instance]
          end

          def embedding_provenance_valid?(provenance:, task: nil, **)
            return false unless provenance.is_a?(Hash)
            return false unless provenance[:space_id].is_a?(String) && provenance[:space_id].match?(/\A[0-9a-f]{64}\z/)
            return false unless embedding_provenance_identity_valid?(provenance: provenance)
            return false unless provenance[:dimensions].is_a?(Integer) && provenance[:dimensions].positive?
            return false unless %w[document query].include?(provenance[:task]) && (!task || provenance[:task] == task.to_s)
            return false unless provenance[:normalization] == 'none'

            provenance[:prefixes].is_a?(Hash) && %i[document query].all? { |key| provenance[:prefixes][key].is_a?(String) }
          end

          def embedding_provenance_identity_valid?(provenance:, **)
            return false unless %i[provider model instance].all? { |key| provenance[key].is_a?(String) && !provenance[key].strip.empty? }

            revision = provenance[:model_revision]
            case provenance[:identity_source]
            when 'revision' then revision.is_a?(String) && !revision.strip.empty?
            when 'instance' then provenance.key?(:model_revision) && revision.nil?
            else false
            end
          end
        end
      end
    end
  end
end
