# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/extensions/apollo/helpers/capability'
require 'legion/extensions/apollo/runners/embedding'
require 'legion/extensions/apollo/runners/knowledge'
require 'legion/extensions/apollo/transport/messages/writeback'

module Legion
  module Extensions
    module Apollo
      module Runners
        module Writeback
          include Legion::Logging::Helper
          extend Legion::Extensions::Apollo::Helpers::Capability

          extend self

          def handle_vectorize(content:, embedding: nil, embedding_provenance: nil, identity_principal_id: nil,
                               identity_id: nil, identity_canonical_name: nil, **payload)
            generated = Legion::Extensions::Apollo::Runners::Embedding.document(
              text: content, vector: embedding, provenance: embedding_provenance
            )
            writeback_deliver(
              payload:       payload.merge(
                content: content, identity_principal_id: identity_principal_id,
                identity_id: identity_id, identity_canonical_name: identity_canonical_name,
                embedding: generated[:vector], embedding_provenance: generated[:provenance]
              ),
              has_embedding: true
            )
            { success: true, action: :vectorized }
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.writeback.handle_vectorize')
            raise
          end

          def writeback_deliver(payload:, has_embedding:, **)
            can_write = has_embedding && capability_can_write?
            result = if can_write
                       Legion::Extensions::Apollo::Runners::Knowledge.handle_ingest(**payload)
                     else
                       publication = payload.except(:routing_key, :exchange)
                       Legion::Extensions::Apollo::Transport::Messages::Writeback.new(
                         **publication, has_embedding: has_embedding
                       ).publish!
                     end
            accepted = can_write ? result.is_a?(Hash) && result[:success] == true : result.is_a?(Hash) && result[:accepted] == true
            raise IOError, "Apollo writeback delivery failed: #{result.inspect}" unless accepted

            { success: true, result: result }
          end
        end
      end
    end
  end
end
