# frozen_string_literal: true

require 'digest'
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

          # Fail forward across legion-llm releases: 0.16.9 returns flat routing
          # fields without embedding_provenance. Derive the same space identity
          # 0.16.10+ returns (key order and values mirror its embedding_identity)
          # so vectors from both API shapes compare in one space.
          def embedding_legacy_provenance(result:, task:, **)
            vector = result[:vector]
            provider = result[:provider].to_s
            model = result[:model].to_s
            instance = result[:instance].to_s
            return nil unless vector.is_a?(Array) && !vector.empty?
            return nil if provider.strip.empty? || model.strip.empty? || instance.strip.empty?

            dimensions = result[:dimensions]
            dimensions = vector.length unless dimensions.is_a?(Integer) && dimensions.positive?
            identity = {
              provider:        provider,
              model:           model,
              model_revision:  nil,
              identity_source: 'instance',
              instance:        instance,
              dimensions:      dimensions,
              prefixes:        { document: embedding_legacy_prefix(model: model, task: :document),
                                 query:    embedding_legacy_prefix(model: model, task: :query) },
              normalization:   'none'
            }
            identity.merge(space_id: Digest::SHA256.hexdigest(Legion::JSON.dump(identity)), task: task.to_s)
          end

          # Registry semantics mirror legion-llm's prefix_for: the model base
          # (before ':') keys the configured prefix registry; absent policies are ''.
          def embedding_legacy_prefix(model:, task:, **)
            llm = Legion::Settings[:llm]
            embedding = llm[:embedding] if llm.is_a?(Hash)
            registry = embedding[:prefix_registry] if embedding.is_a?(Hash)
            registry = {} unless registry.is_a?(Hash)
            base = model.to_s.split(':').first
            model_prefixes = registry[base] || {}
            (model_prefixes[task] || model_prefixes[task.to_s]).to_s
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
