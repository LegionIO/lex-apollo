# frozen_string_literal: true

module Legion
  module Extensions
    module Apollo
      module Transport
        extend Legion::Extensions::Transport

        def self.additional_e_to_q
          [
            { from:        Legion::Extensions::Apollo::Transport::Exchanges::Apollo,
              to:          Legion::Extensions::Apollo::Transport::Queues::Ingest,
              routing_key: 'legion.apollo.ingest' },
            { from:        Legion::Extensions::Apollo::Transport::Exchanges::Apollo,
              to:          Legion::Extensions::Apollo::Transport::Queues::QueryResponder,
              routing_key: 'legion.apollo.query' },
            { from:        Legion::Extensions::Apollo::Transport::Exchanges::Apollo,
              to:          Legion::Extensions::Apollo::Transport::Queues::WritebackStore,
              routing_key: 'legion.apollo.writeback.store' },
            { from:        Legion::Extensions::Apollo::Transport::Exchanges::Apollo,
              to:          Legion::Extensions::Apollo::Transport::Queues::WritebackVectorize,
              routing_key: 'legion.apollo.writeback.vectorize' },
            { from:        Legion::Extensions::Apollo::Transport::Exchanges::LlmAudit,
              to:          Legion::Extensions::Apollo::Transport::Queues::GasSubscriber,
              routing_key: 'llm.audit.complete' }
          ]
        end
      end
    end
  end
end
