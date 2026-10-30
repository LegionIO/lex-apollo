# frozen_string_literal: true

require_relative '../helpers/embedding'
require_relative '../helpers/capability'
require_relative '../transport/messages/writeback'
require_relative 'knowledge'

module Legion
  module Extensions
    module Apollo
      module Runners
        module Writeback
          include Legion::Extensions::Helpers::Lex
          extend Legion::Logging::Helper

          module_function

          def handle_vectorize(content:, embedding: nil, embedding_provenance: nil, identity_principal_id: nil,
                               identity_id: nil, identity_canonical_name: nil, **payload)
            generated = Legion::Extensions::Apollo::Helpers::Embedding.document(text: content, vector: embedding, provenance: embedding_provenance)
            writeback_deliver(payload: payload.merge(content: content, identity_principal_id: identity_principal_id,
                                                     identity_id: identity_id, identity_canonical_name: identity_canonical_name,
                                                     embedding: generated[:vector], embedding_provenance: generated[:provenance]), has_embedding: true)
            { success: true, action: :vectorized }
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.writeback.handle_vectorize')
            raise
          end

          def writeback_deliver(payload:, has_embedding:, **)
            if has_embedding && Legion::Extensions::Apollo::Helpers::Capability.can_write?
              result = Object.new.extend(Legion::Extensions::Apollo::Runners::Knowledge).handle_ingest(**payload)
              raise IOError, "Apollo writeback ingestion failed: #{result.inspect}" unless result.is_a?(Hash) && result[:success] == true
            else
              publication = payload.except(:routing_key, :exchange)
              result = Legion::Extensions::Apollo::Transport::Messages::Writeback.new(**publication, has_embedding: has_embedding).publish
              raise IOError, "Apollo writeback publication failed: #{result.inspect}" unless result.is_a?(Hash) && result[:accepted] == true
            end
            { success: true, result: result }
          end
        end
      end
    end
  end
end
