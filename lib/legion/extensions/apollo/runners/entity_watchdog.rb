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
            return { success: true, ingested: 0, reason: :disabled } unless settings[:entity_watchdog][:enabled] == true

            return { success: false, error: 'task_log_not_available', ingested: 0 } if data_model_task_log.nil?

            task_logs = entity_watchdog_recent_task_logs
            return { success: true, ingested: 0, reason: :no_logs } if task_logs.empty?

            @entity_watchdog_processed_hashes ||= {}
            hash_limit = [settings[:entity_watchdog][:log_limit] * 4, 100].max
            ingested = 0
            failed = 0
            task_logs.each do |task_log|
              text_hash = Digest::SHA256.hexdigest([task_log[:access_scope], task_log[:identity_principal_id],
                                                    task_log[:text]].join("\0"))
              next if @entity_watchdog_processed_hashes.key?(text_hash)

              result = entity_watchdog_ingest_text(task_log: task_log)
              ingested += result[:ingested]
              unless result[:success]
                failed += 1
                next
              end

              @entity_watchdog_processed_hashes[text_hash] = true
              @entity_watchdog_processed_hashes.shift while @entity_watchdog_processed_hashes.size > hash_limit
            end

            log.info("EntityWatchdog ingested=#{ingested} logs_scanned=#{task_logs.size} failed=#{failed}")
            { success: failed.zero?, ingested: ingested, logs_scanned: task_logs.size, failed: failed }
          rescue StandardError => e
            handle_exception(e, level: :error, operation: 'apollo.entity_watchdog.scan_and_ingest')
            { success: false, error: e.message, ingested: ingested || 0 }
          end

          private

          def entity_watchdog_recent_task_logs
            cutoff = Time.now - settings[:entity_watchdog][:lookback_seconds]
            public_scopes = %w[global public]
            visibility = [{ access_scope: public_scopes }]
            identity = entity_watchdog_process_identity
            if identity[:principal_id]
              visibility << { access_scope: %w[private team], identity_principal_id: identity[:principal_id] }
              if identity[:identity_id]
                visibility << { access_scope: %w[private team], identity_principal_id: nil,
                                identity_id: identity[:identity_id] }
              end
            end
            Legion::Data::Model::TaskLog.where { created_at >= cutoff }
                                        .where(Sequel.|(*visibility))
                                        .order(Sequel.desc(:created_at))
                                        .limit(settings[:entity_watchdog][:log_limit])
                                        .select(:entry, :access_scope, :identity_principal_id).all.filter_map do |row|
              text = row[:entry].to_s
              next if text.empty?

              scope = public_scopes.include?(row[:access_scope]) ? 'global' : row[:access_scope]
              { text: text, access_scope: scope,
                identity_principal_id: scope == 'global' ? nil : (row[:identity_principal_id] || identity[:principal_id]) }
            end.uniq
          end

          def entity_watchdog_process_identity
            return {} unless defined?(Legion::Identity::Process)

            principal_id = Legion::Identity::Process.db_principal_id
            identity_id = Legion::Identity::Process.db_identity_id
            identity = {}
            identity[:principal_id] = principal_id if principal_id.is_a?(Integer) && principal_id.positive?
            identity[:identity_id] = identity_id if identity_id.is_a?(Integer) && identity_id.positive?
            identity
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.entity_watchdog.process_identity')
            {}
          end

          def entity_watchdog_ingest_text(task_log:)
            ingested = 0
            result = Legion::Extensions::Apollo::Runners::EntityExtractor.extract_entities(
              text: task_log[:text], entity_types: settings[:entity_watchdog][:types],
              min_confidence: settings[:entity_watchdog][:min_confidence]
            )
            return { success: false, ingested: 0 } unless result[:success] && result[:source] != :unavailable

            result[:entities].each do |entity|
              next if entity_watchdog_entity_exists?(entity: entity, task_log: task_log)

              entity_watchdog_publish(entity: entity, task_log: task_log)
              ingested += 1
            end
            { success: true, ingested: ingested }
          rescue StandardError => e
            handle_exception(e, level: :error, operation: 'apollo.entity_watchdog.ingest_text')
            { success: false, ingested: ingested, error: e.message }
          end

          def entity_watchdog_entity_exists?(entity:, task_log:)
            result = Legion::Extensions::Apollo::Runners::Knowledge.retrieve_relevant(
              query: entity[:name].to_s, limit: 1,
              min_confidence: settings[:entity_watchdog][:exists_min_confidence],
              tags: [entity[:type].to_s], requesting_principal_id: task_log[:identity_principal_id] || 0
            )
            raise "Apollo entity lookup failed: #{result[:error]}" unless result[:success]

            closest = result[:entries].first
            return false unless closest

            closest.fetch(:distance) <= (1.0 - settings[:entity_watchdog][:dedup_threshold])
          end

          def entity_watchdog_publish(entity:, task_log:)
            Legion::Extensions::Apollo::Transport::Messages::Ingest.new(
              content: "#{entity[:type].to_s.capitalize}: #{entity[:name]}",
              content_type: 'concept', tags: [entity[:type].to_s, 'entity_watchdog'],
              source_agent: 'lex-apollo:entity_watchdog',
              access_scope: task_log[:access_scope], identity_principal_id: task_log[:identity_principal_id],
              context: { entity_type: entity[:type], original_name: entity[:name] }
            ).publish!
            log.info("EntityWatchdog published entity type=#{entity[:type]} name=#{entity[:name]}")
          end
        end
      end
    end
  end
end
