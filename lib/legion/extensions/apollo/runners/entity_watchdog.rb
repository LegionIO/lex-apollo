# frozen_string_literal: true

require 'digest'
require 'legion/logging/helper'
require 'legion/settings/helper'
require 'legion/extensions/apollo/runners/entity_extractor'
require 'legion/extensions/apollo/runners/knowledge'
require 'legion/extensions/apollo/transport/messages/ingest'
require 'legion/extensions/apollo/helpers/data_models'

module Legion
  module Extensions
    module Apollo
      module Runners
        module EntityWatchdog
          include Legion::Logging::Helper
          include Legion::Settings::Helper
          extend Legion::Extensions::Apollo::Helpers::DataModels
          extend self

          def scan_and_ingest(**)
            return { success: false, error: 'task_log_not_available', ingested: 0 } if data_model_task_log.nil?

            texts = entity_watchdog_recent_task_log_texts
            return { success: true, ingested: 0, reason: :no_logs } if texts.empty?

            @entity_watchdog_processed_hashes ||= {}
            hash_limit = [settings[:entity_watchdog][:log_limit] * 4, 100].max
            ingested = 0
            failed = 0
            texts.each do |text|
              text_hash = Digest::SHA256.hexdigest(text)
              next if @entity_watchdog_processed_hashes.key?(text_hash)

              result = entity_watchdog_ingest_text(text: text)
              ingested += result[:ingested]
              unless result[:success]
                failed += 1
                next
              end

              @entity_watchdog_processed_hashes[text_hash] = true
              @entity_watchdog_processed_hashes.shift while @entity_watchdog_processed_hashes.size > hash_limit
            end

            log.info("EntityWatchdog ingested=#{ingested} logs_scanned=#{texts.size} failed=#{failed}")
            { success: failed.zero?, ingested: ingested, logs_scanned: texts.size, failed: failed }
          rescue StandardError => e
            handle_exception(e, level: :error, operation: 'apollo.entity_watchdog.scan_and_ingest')
            { success: false, error: e.message, ingested: ingested || 0 }
          end

          private

          def entity_watchdog_recent_task_log_texts
            cutoff = Time.now - settings[:entity_watchdog][:lookback_seconds]
            Legion::Data::Model::TaskLog.where { created_at >= cutoff }
                                        .order(Sequel.desc(:created_at))
                                        .limit(settings[:entity_watchdog][:log_limit])
                                        .select_map(:entry).map(&:to_s).reject(&:empty?).uniq
          end

          def entity_watchdog_ingest_text(text:)
            ingested = 0
            result = Legion::Extensions::Apollo::Runners::EntityExtractor.extract_entities(
              text: text, entity_types: settings[:entity_watchdog][:types],
              min_confidence: settings[:entity_watchdog][:min_confidence]
            )
            return { success: false, ingested: 0 } unless result[:success] && result[:source] != :unavailable

            result[:entities].each do |entity|
              next if entity_watchdog_entity_exists?(entity: entity)

              entity_watchdog_publish(entity: entity)
              ingested += 1
            end
            { success: true, ingested: ingested }
          rescue StandardError => e
            handle_exception(e, level: :error, operation: 'apollo.entity_watchdog.ingest_text')
            { success: false, ingested: ingested, error: e.message }
          end

          def entity_watchdog_entity_exists?(entity:)
            result = Legion::Extensions::Apollo::Runners::Knowledge.retrieve_relevant(
              query: entity[:name].to_s, limit: 1,
              min_confidence: settings[:entity_watchdog][:exists_min_confidence],
              tags: [entity[:type].to_s]
            )
            raise "Apollo entity lookup failed: #{result[:error]}" unless result[:success]

            closest = result[:entries].first
            return false unless closest

            closest.fetch(:distance) <= (1.0 - settings[:entity_watchdog][:dedup_threshold])
          end

          def entity_watchdog_publish(entity:)
            Legion::Extensions::Apollo::Transport::Messages::Ingest.new(
              content: "#{entity[:type].to_s.capitalize}: #{entity[:name]}",
              content_type: 'concept', tags: [entity[:type].to_s, 'entity_watchdog'],
              source_agent: 'lex-apollo:entity_watchdog',
              context: { entity_type: entity[:type], original_name: entity[:name] }
            ).publish!
            log.info("EntityWatchdog published entity type=#{entity[:type]} name=#{entity[:name]}")
          end
        end
      end
    end
  end
end
