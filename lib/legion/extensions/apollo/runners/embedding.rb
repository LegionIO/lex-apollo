# frozen_string_literal: true

require 'legion/llm'
require 'legion/logging/helper'
require 'legion/extensions/apollo/helpers/embedding'
require 'legion/extensions/apollo/helpers/similarity'

module Legion
  module Extensions
    module Apollo
      module Runners
        module Embedding
          include Legion::Logging::Helper
          extend Legion::Extensions::Apollo::Helpers::Embedding
          extend Legion::Extensions::Apollo::Helpers::Similarity

          extend self

          def generate(text:, task: :document, provider: nil, model: nil, instance: nil, dimensions: nil, **)
            result = Legion::LLM::Call::Embeddings.generate(
              text: text, task: task, provider: provider, model: model, instance: instance, dimensions: dimensions
            )
            raise Legion::Extensions::Apollo::Helpers::Embedding::Error, 'Embedding generation did not return a result' unless result.is_a?(Hash)

            provenance = embedding_parse_provenance(value: result[:embedding_provenance])
            vector = result[:vector]
            unless embedding_valid?(vector: vector, provenance: provenance, task: task)
              raise Legion::Extensions::Apollo::Helpers::Embedding::Error, 'Embedding generation returned an invalid vector or provenance'
            end
            if dimensions && dimensions != vector.length
              raise Legion::Extensions::Apollo::Helpers::Embedding::Error,
                    'Embedding dimensions differ from the request'
            end

            %i[provider model instance dimensions].each do |key|
              unless result[key].to_s == provenance[key].to_s
                raise Legion::Extensions::Apollo::Helpers::Embedding::Error,
                      "Embedding #{key} differs from its provenance"
              end
            end
            { vector: vector, provenance: provenance }
          rescue Legion::LLM::LLMError => e
            handle_exception(e, level: :warn, operation: 'apollo.embedding.generate')
            raise
          end

          def document(text:, vector: nil, provenance: nil, **)
            parsed_vector = similarity_parse_vector(vector: vector)
            parsed_provenance = embedding_parse_provenance(value: provenance)
            return { vector: parsed_vector, provenance: parsed_provenance } if embedding_valid?(vector: parsed_vector, provenance: parsed_provenance,
                                                                                                task: :document)

            generate(text: text, task: :document)
          end
        end
      end
    end
  end
end
