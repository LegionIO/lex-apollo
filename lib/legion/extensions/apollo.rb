# frozen_string_literal: true

require 'legion/extensions/apollo/version'
require 'legion/extensions/apollo/helpers/confidence'
require 'legion/extensions/apollo/helpers/similarity'
require 'legion/extensions/apollo/helpers/graph_query'
require 'legion/extensions/apollo/helpers/tag_normalizer'
require 'legion/extensions/apollo/helpers/capability'
require 'legion/extensions/apollo/helpers/writeback'
require 'legion/extensions/apollo/runners/knowledge'
require 'legion/extensions/apollo/runners/expertise'
require 'legion/extensions/apollo/runners/maintenance'
require 'legion/extensions/apollo/runners/entity_extractor'
require 'legion/extensions/apollo/runners/gas'
require 'legion/extensions/apollo/runners/request'

require 'legion/extensions/apollo/api' if defined?(Sinatra)

if defined?(Legion::Transport)
  require 'legion/extensions/apollo/transport/exchanges/apollo'
  require 'legion/extensions/apollo/transport/exchanges/llm_audit'
  require 'legion/extensions/apollo/transport/queues/ingest'
  require 'legion/extensions/apollo/transport/queues/query'
  require 'legion/extensions/apollo/transport/queues/gas'
  require 'legion/extensions/apollo/transport/messages/ingest'
  require 'legion/extensions/apollo/transport/messages/query'
  require 'legion/extensions/apollo/transport/messages/writeback'
  require 'legion/extensions/apollo/transport/queues/writeback_store'
  require 'legion/extensions/apollo/transport/queues/writeback_vectorize'
end

module Legion
  module Extensions
    module Apollo
      extend Legion::Extensions::Core if Legion::Extensions.const_defined? :Core

      def self.remote_invocable?
        false
      end
    end
  end
end

# Entity watchdog runs as Actor::EntityWatchdog (Every actor, 120s interval).
# PhaseWiring.register_handler was removed — the watchdog scans task logs independently.
