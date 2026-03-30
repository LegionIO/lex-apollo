# frozen_string_literal: true

require 'legion/transport/queue'

module Legion
  module Extensions
    module Apollo
      module Transport
        module Queues
          class WritebackStore < Legion::Transport::Queue
            def queue_name
              'legion.apollo.writeback.store'
            end

            def queue_options
              { manual_ack: true, durable: true, arguments: { 'x-dead-letter-exchange': 'legion.apollo.dlx' } }
            end
          end
        end
      end
    end
  end
end
