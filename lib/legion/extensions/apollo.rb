# frozen_string_literal: true

require 'legion/extensions/apollo/version'
require 'legion/extensions/apollo/helpers/confidence'
require 'legion/extensions/apollo/helpers/similarity'
require 'legion/extensions/apollo/helpers/graph_query'
require 'legion/extensions/apollo/runners/knowledge'
require 'legion/extensions/apollo/runners/expertise'
require 'legion/extensions/apollo/runners/maintenance'

if defined?(Legion::Transport)
  require 'legion/extensions/apollo/transport/exchanges/apollo'
  require 'legion/extensions/apollo/transport/queues/ingest'
  require 'legion/extensions/apollo/transport/queues/query'
  require 'legion/extensions/apollo/transport/messages/ingest'
  require 'legion/extensions/apollo/transport/messages/query'
end

module Legion
  module Extensions
    module Apollo
      extend Legion::Extensions::Core if Legion::Extensions.const_defined? :Core
    end
  end
end
