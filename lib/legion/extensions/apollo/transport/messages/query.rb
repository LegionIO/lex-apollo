# frozen_string_literal: true

require 'legion/transport/message'

module Legion
  module Extensions
    module Apollo
      module Transport
        module Messages
          class Query < Legion::Transport::Message
            def exchange
              Legion::Extensions::Apollo::Transport::Exchanges::Apollo
            end

            def routing_key
              'legion.apollo.query'
            end

            def message
              @options.slice(:action, :query, :entry_id, :limit, :min_confidence, :status, :tags,
                             :domain, :agent_id, :requesting_principal_id, :tag_match, :exclude_source_agents,
                             :relation_types, :depth, :reply_to, :correlation_id)
            end

            def type
              'apollo_query'
            end
          end
        end
      end
    end
  end
end
