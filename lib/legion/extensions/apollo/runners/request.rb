# frozen_string_literal: true

module Legion
  module Extensions
    module Apollo
      module Runners
        module Request
          extend self

          def self.data_required?
            false
          end

          def query(text:, limit: Helpers::GraphQuery.default_query_limit, min_confidence: Helpers::GraphQuery.default_query_min_confidence, tags: nil, # rubocop:disable Metrics/ParameterLists
                    domain: nil, agent_id: 'unknown', **)
            if local_service_available?
              knowledge_host.handle_query(query: text, limit: limit, min_confidence: min_confidence,
                                          tags: tags, domain: domain, agent_id: agent_id)
            elsif transport_available?
              publish_query(action: :query, query: text, limit: limit, min_confidence: min_confidence,
                            tags: tags, domain: domain)
            else
              { success: false, error: :no_path_available }
            end
          end

          def retrieve(text:, limit: 5, min_confidence: Helpers::GraphQuery.default_query_min_confidence, tags: nil, domain: nil, **)
            if local_service_available?
              knowledge_host.retrieve_relevant(query: text, limit: limit, min_confidence: min_confidence,
                                               tags: tags, domain: domain)
            elsif transport_available?
              publish_query(action: :query, query: text, limit: limit, min_confidence: min_confidence,
                            tags: tags, domain: domain)
            else
              { success: false, error: :no_path_available }
            end
          end

          def ingest(content:, content_type:, tags: [], source_agent: 'unknown', **)
            if local_service_available?
              knowledge_host.handle_ingest(content: content, content_type: content_type,
                                           tags: tags, source_agent: source_agent, **)
            elsif transport_available?
              publish_ingest(content: content, content_type: content_type,
                             tags: tags, source_agent: source_agent, **)
            else
              { success: false, error: :no_path_available }
            end
          end

          def traverse(entry_id:, depth: Helpers::GraphQuery.default_depth, relation_types: nil, agent_id: 'unknown', **)
            if local_service_available?
              knowledge_host.handle_traverse(entry_id: entry_id, depth: depth,
                                             relation_types: relation_types, agent_id: agent_id)
            elsif transport_available?
              publish_query(action: :traverse, entry_id: entry_id, depth: depth,
                            relation_types: relation_types)
            else
              { success: false, error: :no_path_available }
            end
          end

          private

          def knowledge_host
            @knowledge_host ||= Object.new.extend(Knowledge)
          end

          def local_service_available?
            defined?(Legion::Data::Model::ApolloEntry) &&
              defined?(Knowledge)
          end

          def transport_available?
            defined?(Legion::Transport) &&
              Legion::Transport.respond_to?(:connected?) &&
              Legion::Transport.connected?
          end

          def publish_query(**payload)
            Transport::Messages::Query.new(payload).publish
            { success: true, dispatched: :transport, payload: payload }
          rescue StandardError => e
            { success: false, error: e.message }
          end

          def publish_ingest(**payload)
            Transport::Messages::Ingest.new(payload).publish
            { success: true, dispatched: :transport, payload: payload }
          rescue StandardError => e
            { success: false, error: e.message }
          end
        end
      end
    end
  end
end
