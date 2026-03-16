# frozen_string_literal: true

require 'legion/transport/exchange' if defined?(Legion::Transport)

module Legion
  module Extensions
    module Apollo
      module Transport
        module Exchanges
          class Apollo < Legion::Transport::Exchange
            def exchange_name
              'apollo'
            end
          end
        end
      end
    end
  end
end
