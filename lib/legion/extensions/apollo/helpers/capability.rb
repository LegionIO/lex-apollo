# frozen_string_literal: true

module Legion
  module Extensions
    module Apollo
      module Helpers
        module Capability
          extend Legion::Logging::Helper
          extend Legion::Settings::Helper

          PRIVILEGE_MUTEX = Mutex.new

          module_function

          # SSOT gate: the sole selection authority for embeddings is the
          # router (Call::Embeddings.generate with no provider arg →
          # Router.next_lane). can_embed? asks the one capability fact that
          # matches that selection — is there an embedding-type lane the
          # router can select? — against the same registry lanes the router
          # reads. Provider-agnostic (no ollama pin, no hardcoded model
          # list); no parallel settings-based "second domain".
          def can_embed?
            return false unless defined?(Legion::LLM) && Legion::LLM.started?

            Legion::LLM.can_embed?
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.capability.can_embed')
            false
          end

          def can_write?
            return false unless apollo_write_enabled?
            return false unless defined?(Legion::Data) && Legion::Data.connected?

            check_db_write_privilege
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.capability.can_write')
            false
          end

          def apollo_write_enabled?
            settings[:data][:apollo_write] == true
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.capability.apollo_write_enabled')
            false
          end

          def check_db_write_privilege
            PRIVILEGE_MUTEX.synchronize do
              return @apollo_write_privilege unless @apollo_write_privilege.nil?

              @apollo_write_privilege = Legion::Data.connection
                                                    .fetch("SELECT has_table_privilege(current_user, 'apollo_entries', 'INSERT') AS can_insert")
                                                    .first[:can_insert] == true
            end
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.capability.check_db_write_privilege')
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
