# frozen_string_literal: true

require 'legion/transport'
require 'legion/extensions/apollo/transport/messages/query'
require 'legion/extensions/apollo/transport/messages/ingest'
require 'legion/extensions/apollo/helpers/data_models'
require 'legion/extensions/apollo/runners/knowledge'
module Legion
  module Extensions
    module Apollo
      module Runners
        module Request
          include Legion::Settings::Helper
          include Legion::Logging::Helper
          include Legion::Transport::Helper
          extend Legion::Extensions::Apollo::Helpers::DataModels
          extend self

          def self.data_required?
            false
          end

          def query(text:, limit: settings[:query][:default_limit], min_confidence: settings[:query][:default_min_confidence], tags: nil,
                    domain: nil, agent_id: 'unknown', **)
            if data_model_entry
              Legion::Extensions::Apollo::Runners::Knowledge.handle_query(query: text, limit: limit, min_confidence: min_confidence,
                                                                          tags: tags, domain: domain, agent_id: agent_id, **)
            elsif transport_session_open?
              request_publish_query(action: :query, query: text, limit: limit, min_confidence: min_confidence,
                                    tags: tags, domain: domain, agent_id: agent_id, **)
            else
              { success: false, error: :no_path_available }
            end
          end

          def retrieve(text:, limit: 5, min_confidence: settings[:query][:default_min_confidence], tags: nil, domain: nil, **)
            if data_model_entry
              Legion::Extensions::Apollo::Runners::Knowledge.retrieve_relevant(query: text, limit: limit, min_confidence: min_confidence,
                                                                               tags: tags, domain: domain, **)
            elsif transport_session_open?
              request_publish_query(action: :retrieve, query: text, limit: limit, min_confidence: min_confidence,
                                    tags: tags, domain: domain, **)
            else
              { success: false, error: :no_path_available }
            end
          end

          def ingest(content:, content_type:, tags: [], source_agent: 'unknown', **options)
            if data_model_entry
              Legion::Extensions::Apollo::Runners::Knowledge.handle_ingest(content: content, content_type: content_type,
                                                                           tags: tags, source_agent: source_agent, **options)
            elsif transport_session_open?
              request_publish_ingest(**request_process_identity(options: options), content: content, content_type: content_type,
                                                                                   tags: tags, source_agent: source_agent, **options)
            else
              { success: false, error: :no_path_available }
            end
          end

          def traverse(entry_id:, depth: settings[:graph][:default_depth], relation_types: nil, agent_id: 'unknown', **)
            if data_model_entry
              Legion::Extensions::Apollo::Runners::Knowledge.handle_traverse(entry_id: entry_id, depth: depth,
                                                                             relation_types: relation_types, agent_id: agent_id, **)
            elsif transport_session_open?
              request_publish_query(action: :traverse, entry_id: entry_id, depth: depth,
                                    relation_types: relation_types, agent_id: agent_id, **)
            else
              { success: false, error: :no_path_available }
            end
          end

          private

          def request_process_identity(options:, **)
            return {} if options.key?(:identity_principal_id)
            return {} unless defined?(Legion::Identity::Process)

            identity = {}
            identity[:identity_principal_id] = Legion::Identity::Process.db_principal_id unless options.key?(:identity_principal_id)
            identity[:identity_id] = Legion::Identity::Process.db_identity_id unless options.key?(:identity_id)
            identity[:identity_canonical_name] = Legion::Identity::Process.canonical_name unless options.key?(:identity_canonical_name)
            identity.compact
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.request.process_identity')
            raise
          end

          def request_publish_query(**payload)
            Legion::Extensions::Apollo::Transport::Messages::Query.new(**payload).publish!
            { success: true, dispatched: :transport, payload: payload }
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.request.publish_query')
            { success: false, error: e.message }
          end

          def request_publish_ingest(**payload)
            Legion::Extensions::Apollo::Transport::Messages::Ingest.new(**payload).publish!
            { success: true, dispatched: :transport, payload: payload }
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.request.publish_ingest')
            { success: false, error: e.message }
          end
        end
      end
    end
  end
end
