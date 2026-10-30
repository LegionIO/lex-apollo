# frozen_string_literal: true

require 'legion/json'
require 'sequel'
require 'sequel/extensions/pg_json'
require_relative 'similarity'

module Legion
  module Extensions
    module Apollo
      module Helpers
        module Embedding
          extend Legion::Logging::Helper

          class Error < StandardError; end

          SPACE_FIELDS = %i[space_id provider model model_revision identity_source dimensions prefixes normalization].freeze

          module_function

          def generate(text:, task: :document, provider: nil, model: nil, instance: nil, dimensions: nil, **)
            result = Legion::LLM::Call::Embeddings.generate(text: text, task: task, provider: provider,
                                                            model: model, instance: instance, dimensions: dimensions)
            raise Error, 'Embedding generation did not return a result' unless result.is_a?(Hash)

            provenance = parse_provenance(value: result[:embedding_provenance])
            vector = result[:vector]
            raise Error, 'Embedding generation returned an invalid vector or provenance' unless valid?(vector: vector, provenance: provenance, task: task)
            raise Error, 'Embedding dimensions differ from the request' if dimensions && dimensions != vector.length

            %i[provider model instance dimensions].each do |key|
              raise Error, "Embedding #{key} differs from its provenance" unless result[key].to_s == provenance[key].to_s
            end
            { vector: vector, provenance: provenance }
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.embedding.generate')
            raise if e.is_a?(Error)

            raise Error, e.message
          end

          def document(text:, vector: nil, provenance: nil, **)
            vector = Legion::Extensions::Apollo::Helpers::Similarity.parse_vector(vector: vector)
            provenance = parse_provenance(value: provenance)
            return { vector: vector, provenance: provenance } if valid?(vector: vector, provenance: provenance, task: :document)

            generate(text: text, task: :document)
          end

          def valid?(vector:, provenance:, task: nil, **)
            return false unless vector.is_a?(Array) && !vector.empty?
            return false unless vector.all? { |value| value.is_a?(Numeric) && value.real? && value.finite? }
            return false unless vector.any? { |value| !value.zero? }

            provenance = parse_provenance(value: provenance)
            provenance_valid?(provenance: provenance, task: task) && provenance[:dimensions] == vector.length
          end

          def compatible?(left:, right:, **)
            left = parse_provenance(value: left)
            right = parse_provenance(value: right)
            return false unless provenance_valid?(provenance: left) && provenance_valid?(provenance: right)
            return false unless SPACE_FIELDS.all? { |key| left[key] == right[key] }

            left[:identity_source] == 'revision' || left[:instance] == right[:instance]
          end

          def parse_provenance(value:, **)
            return nil if value.nil?

            value = Legion::JSON.load(value) if value.is_a?(String)
            value = value.to_h if value.is_a?(Sequel::Postgres::JSONHash) || value.is_a?(Sequel::Postgres::JSONBHash)
            return nil unless value.is_a?(Hash)

            value = value.transform_keys { |key| key.is_a?(String) ? key.to_sym : key }
            if value[:prefixes].is_a?(Hash)
              value[:prefixes] = value[:prefixes].transform_keys { |key| key.is_a?(String) ? key.to_sym : key }
            end
            value
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.embedding.parse_provenance')
            nil
          end

          def provenance_valid?(provenance:, task: nil, **)
            return false unless provenance.is_a?(Hash)
            return false unless provenance[:space_id].is_a?(String) && provenance[:space_id].match?(/\A[0-9a-f]{64}\z/)
            return false unless provenance_identity_valid?(provenance: provenance)
            return false unless provenance[:dimensions].is_a?(Integer) && provenance[:dimensions].positive?
            return false unless %w[document query].include?(provenance[:task]) && (!task || provenance[:task] == task.to_s)
            return false unless provenance[:normalization] == 'none'

            provenance[:prefixes].is_a?(Hash) && %i[document query].all? { |key| provenance[:prefixes][key].is_a?(String) }
          end
          private_class_method :provenance_valid?

          def provenance_identity_valid?(provenance:, **)
            return false unless %i[provider model instance].all? { |key| provenance[key].is_a?(String) && !provenance[key].strip.empty? }

            revision = provenance[:model_revision]
            case provenance[:identity_source]
            when 'revision' then revision.is_a?(String) && !revision.strip.empty?
            when 'instance' then provenance.key?(:model_revision) && revision.nil?
            else false
            end
          end
          private_class_method :provenance_identity_valid?
        end
      end
    end
  end
end
