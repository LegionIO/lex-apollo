# frozen_string_literal: true

require 'legion/logging'
require 'legion/settings'
require 'legion/json'
require 'legion/extensions/apollo/version'
require 'legion/extensions/apollo/helpers/confidence'
require 'legion/extensions/apollo/helpers/similarity'
require 'legion/extensions/apollo/helpers/graph_query'
require 'legion/extensions/apollo/helpers/tag_normalizer'
require 'legion/extensions/apollo/helpers/capability'
require 'legion/extensions/apollo/helpers/writeback'
require 'legion/extensions/apollo/helpers/data_models'
require 'legion/extensions/apollo/runners/knowledge'
require 'legion/extensions/apollo/runners/expertise'
require 'legion/extensions/apollo/runners/maintenance'
require 'legion/extensions/apollo/runners/entity_extractor'
require 'legion/extensions/apollo/runners/gas'
require 'legion/extensions/apollo/runners/request'

require 'legion/extensions/apollo/api' if defined?(Sinatra)

if Legion.const_defined?(:Transport, false)
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
      extend Legion::Logging::Helper
      extend Legion::Settings::Helper
      extend Legion::Extensions::Core if Legion::Extensions.const_defined? :Core, false

      def self.remote_invocable?
        false
      end

      def self.default_settings # rubocop:disable Metrics/MethodLength
        {
          confidence:          {
            initial:                  0.5,
            corroboration_boost:      0.3,
            retrieval_boost:          0.02,
            write_gate:               0.6,
            novelty_gate:             0.3,
            corroboration_similarity: 0.9
          },
          power_law_alpha:     0.05,
          decay_threshold:     0.05,
          stale_days:          90,
          decay_min_age_hours: 168,
          graph:               {
            spread_factor:  0.6,
            default_depth:  2,
            min_activation: 0.1
          },
          query:               {
            default_limit:               10,
            default_min_confidence:      0.3,
            retrieval_limit:             5,
            redistribute_min_confidence: 0.5,
            mesh_export_min_confidence:  0.5,
            mesh_export_limit:           100
          },
          gas:                 {
            relate_confidence_gate:   0.7,
            synthesis_confidence_cap: 0.7,
            max_anticipations:        3,
            similar_entries_limit:    3,
            fallback_confidence:      0.5
          },
          maintenance:         {
            force_decay_factor: 0.5
          },
          contradiction:       {
            similar_limit:        10,
            similarity_threshold: 0.7,
            relation_weight:      0.8
          },
          corroboration:       {
            relation_weight:      1.0,
            scan_limit:           50,
            same_provider_weight: 0.5
          },
          expertise:           {
            initial_proficiency: 0.0,
            min_agents_at_risk:  2,
            proficiency_cap:     1.0
          },
          entity_extractor:    {
            min_confidence: 0.7
          },
          entity_watchdog:     {
            concept_keywords:      [],
            types:                 %w[person service repository concept],
            detect_confidence:     0.5,
            exists_min_confidence: 0.1,
            min_confidence:        0.7,
            dedup_threshold:       0.92,
            lookback_seconds:      300,
            log_limit:             50
          },
          domain_isolation:    {
            'claims_optimization' => ['claims_optimization'],
            'clinical_care'       => %w[clinical_care general],
            'general'             => :all
          },
          embedding:           {
            provider: nil,
            model:    nil
          },
          data:                {
            apollo_write: false
          },
          writeback:           {
            enabled:            true,
            min_content_length: 50
          },
          actors:              {
            decay_interval:           3600,
            expertise_interval:       1800,
            corroboration_interval:   900,
            entity_watchdog_interval: 120
          }
        }
      end
    end
  end
end

# Entity watchdog runs as Actor::EntityWatchdog (Every actor, 120s interval).
# PhaseWiring.register_handler was removed — the watchdog scans task logs independently.
