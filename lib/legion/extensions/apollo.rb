# frozen_string_literal: true

require 'legion/extensions/apollo/version'
require 'legion/extensions/apollo/helpers/confidence'
require 'legion/extensions/apollo/helpers/similarity'
require 'legion/extensions/apollo/helpers/graph_query'
require 'legion/extensions/apollo/runners/knowledge'
require 'legion/extensions/apollo/runners/expertise'
require 'legion/extensions/apollo/runners/maintenance'
require 'legion/extensions/apollo/runners/entity_extractor'
require 'legion/extensions/apollo/runners/gas'

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

# Entity watchdog on post_tick_reflection
if defined?(Legion::Gaia::PhaseWiring) && begin
  Legion::Settings.dig(:apollo, :entity_watchdog, :enabled)
rescue StandardError
  false
end
  require 'legion/extensions/apollo/helpers/entity_watchdog'
  Legion::Gaia::PhaseWiring.register_handler(:post_tick_reflection) do |tick_results|
    text = tick_results.is_a?(Hash) ? (tick_results[:content] || tick_results[:output] || '').to_s : tick_results.to_s
    entities = Legion::Extensions::Apollo::Helpers::EntityWatchdog.detect_entities(text: text)
    if entities.any?
      Legion::Extensions::Apollo::Helpers::EntityWatchdog.link_or_create(entities:       entities,
                                                                         source_context: tick_results[:tick_id])
    end
  end
end
