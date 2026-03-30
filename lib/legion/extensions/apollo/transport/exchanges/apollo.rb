# frozen_string_literal: true

require 'legion/transport/exchange'

module Legion
  module Extensions
    module Apollo
      module Transport
        module Exchanges
          class Apollo < Legion::Transport::Exchange
            def exchange_name
              'legion.apollo'
            end
          end
        end
      end
    end
  end
end
