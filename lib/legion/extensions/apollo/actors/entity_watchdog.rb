# frozen_string_literal: true

require 'legion/extensions/actors/every'
require_relative '../runners/knowledge'
require_relative '../runners/entity_extractor'

module Legion
  module Extensions
    module Apollo
      module Actor
        class EntityWatchdog < Legion::Extensions::Actors::Every
          include Legion::Extensions::Apollo::Runners::Knowledge
          include Legion::Extensions::Apollo::Runners::EntityExtractor

          DEDUP_THRESHOLD_DEFAULT   = 0.92
          TASK_LOG_LOOKBACK_SECONDS = 300
          TASK_LOG_LIMIT            = 50

          def runner_class    = self.class
          def runner_function = 'scan_and_ingest'
          def time            = 120
          def run_now?        = false
          def use_runner?     = false
          def check_subtask?  = false
          def generate_task?  = false

          def enabled?
            defined?(Legion::Extensions::Apollo::Runners::EntityExtractor) &&
              defined?(Legion::Transport)
          rescue StandardError
            false
          end

          def scan_and_ingest
            texts = recent_task_log_texts
            return { success: true, ingested: 0, reason: :no_logs } if texts.empty?

            ingested = 0
            texts.each do |text|
              result = extract_entities(
                text:           text,
                entity_types:   entity_types,
                min_confidence: min_entity_confidence
              )
              next unless result[:success]

              result[:entities].each do |entity|
                next if entity_exists_in_apollo?(entity)

                publish_entity_ingest(entity)
                ingested += 1
              end
            end

            log.debug("EntityWatchdog: ingested #{ingested} new entities from #{texts.size} log entries")
            { success: true, ingested: ingested, logs_scanned: texts.size }
          rescue StandardError => e
            log.error("EntityWatchdog scan_and_ingest failed: #{e.message}")
            { success: false, error: e.message }
          end

          def recent_task_log_texts
            return [] unless defined?(Legion::Data) && defined?(Legion::Data::Model::TaskLog)

            cutoff = Time.now - TASK_LOG_LOOKBACK_SECONDS
            logs = Legion::Data::Model::TaskLog
                   .where { created_at >= cutoff }
                   .order(Sequel.desc(:created_at))
                   .limit(TASK_LOG_LIMIT)
                   .select_map(:message)
            logs.map(&:to_s).reject(&:empty?).uniq
          rescue StandardError
            []
          end

          def entity_exists_in_apollo?(entity)
            result = retrieve_relevant(
              query:          entity[:name].to_s,
              limit:          1,
              min_confidence: 0.1,
              tags:           [entity[:type].to_s]
            )
            return false unless result[:success] && result[:count].positive?

            closest = result[:entries].first
            distance = closest[:distance].to_f
            distance <= (1.0 - dedup_similarity_threshold)
          rescue StandardError
            false
          end

          def publish_entity_ingest(entity)
            return unless defined?(Legion::Extensions::Apollo::Transport::Messages::Ingest)

            Legion::Extensions::Apollo::Transport::Messages::Ingest.new(
              content:      "#{entity[:type].to_s.capitalize}: #{entity[:name]}",
              content_type: 'concept',
              tags:         [entity[:type].to_s, 'entity_watchdog'],
              source_agent: 'lex-apollo:entity_watchdog',
              context:      { entity_type: entity[:type], original_name: entity[:name] }
            ).publish
          rescue StandardError => e
            log.error("EntityWatchdog publish failed: #{e.message}")
          end

          def entity_types
            if defined?(Legion::Settings)
              types = Legion::Settings.dig(:apollo, :entity_watchdog, :types)
              return Array(types).map(&:to_s) if types
            end
            %w[person service repository concept]
          end

          def min_entity_confidence
            if defined?(Legion::Settings)
              val = Legion::Settings.dig(:apollo, :entity_watchdog, :min_confidence)
              return val.to_f if val
            end
            0.7
          end

          def dedup_similarity_threshold
            if defined?(Legion::Settings)
              val = Legion::Settings.dig(:apollo, :entity_watchdog, :dedup_threshold)
              return val.to_f if val
            end
            DEDUP_THRESHOLD_DEFAULT
          end
        end
      end
    end
  end
end
