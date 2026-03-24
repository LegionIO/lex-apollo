# frozen_string_literal: true

require 'legion/transport/queue' if defined?(Legion::Transport)

module Legion
  module Extensions
    module Apollo
      module Transport
        module Queues
          class GasSubscriber < Legion::Transport::Queue
            def queue_name
              'apollo.gas'
            end

            def queue_options
              { manual_ack: true, durable: true, arguments: { 'x-dead-letter-exchange': 'apollo.dlx' } }
            end
          end
        end
      end
    end
  end
end
