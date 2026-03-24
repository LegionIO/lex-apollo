# frozen_string_literal: true

require 'legion/transport/exchange' if defined?(Legion::Transport)

module Legion
  module Extensions
    module Apollo
      module Transport
        module Exchanges
          class LlmAudit < Legion::Transport::Exchange
            def exchange_name
              'llm.audit'
            end
          end
        end
      end
    end
  end
end
