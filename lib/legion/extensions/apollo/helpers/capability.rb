# frozen_string_literal: true

module Legion
  module Extensions
    module Apollo
      module Helpers
        module Capability
          EMBEDDING_MODELS = %w[mxbai-embed-large bge-large snowflake-arctic-embed].freeze

          module_function

          def log
            Legion::Logging
          end

          def can_embed?
            return false unless defined?(Legion::LLM) && Legion::LLM.started?

            ollama_embedding_available? || cloud_embedding_configured?
          rescue StandardError => e
            log.warn("Apollo Capability.can_embed? failed: #{e.message}")
            false
          end

          def can_write?
            return false unless apollo_write_enabled?
            return false unless defined?(Legion::Data) && Legion::Data.connected?

            check_db_write_privilege
          rescue StandardError => e
            log.warn("Apollo Capability.can_write? failed: #{e.message}")
            false
          end

          def apollo_write_enabled?
            Legion::Settings.dig(:data, :apollo_write) == true
          rescue StandardError => e
            log.warn("Apollo Capability.apollo_write_enabled? failed: #{e.message}")
            false
          end

          def ollama_embedding_available?
            return false unless defined?(Legion::LLM::Discovery::Ollama)

            EMBEDDING_MODELS.any? { |m| Legion::LLM::Discovery::Ollama.model_available?(m) }
          rescue StandardError => e
            log.warn("Apollo Capability.ollama_embedding_available? failed: #{e.message}")
            false
          end

          def cloud_embedding_configured?
            provider = Legion::Settings.dig(:apollo, :embedding, :provider)
            model = Legion::Settings.dig(:apollo, :embedding, :model)
            !provider.nil? && !model.nil?
          rescue StandardError => e
            log.warn("Apollo Capability.cloud_embedding_configured? failed: #{e.message}")
            false
          end

          def check_db_write_privilege
            return @apollo_write_privilege unless @apollo_write_privilege.nil?

            @apollo_write_privilege = Legion::Data.connection
                                                  .fetch("SELECT has_table_privilege(current_user, 'apollo_entries', 'INSERT') AS can_insert")
                                                  .first[:can_insert] == true
          rescue StandardError => e
            log.warn("Apollo Capability.check_db_write_privilege failed: #{e.message}")
            @apollo_write_privilege = false
          end

          def reset!
            @apollo_write_privilege = nil
          end
        end
      end
    end
  end
end
