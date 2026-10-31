# frozen_string_literal: true

require 'digest'
require 'socket'
require_relative '../runners/writeback'

module Legion
  module Extensions
    module Apollo
      module Helpers
        module Writeback
          extend Legion::Logging::Helper
          extend Legion::Settings::Helper

          RESEARCH_TOOLS = %w[read_file search_files search_content run_command].freeze
          MAX_CONTENT_LENGTH = 4000
          MIN_CONTENT_LENGTH = 50

          module_function

          def evaluate_and_route(request:, response:, enrichments: {}, **)
            return unless writeback_enabled?
            return unless should_capture?(response: response, enrichments: enrichments)

            payload = build_payload(request: request, response: response)
            route_payload(payload: payload)
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.writeback.evaluate_and_route')
            raise
          end

          def should_capture?(response:, enrichments:, **)
            content = response_content(response: response)
            return false if content.nil? || content.length < min_content_length

            extract_tool_calls(response: response, enrichments: enrichments).any? do |call|
              name = call.respond_to?(:name) ? call.name : call[:name] || call['name']
              RESEARCH_TOOLS.include?(name)
            end
          end

          def build_payload(request:, response:, source_channel: nil, **)
            content = response_content(response: response)[0...MAX_CONTENT_LENGTH]
            caller_identity = extract_identity(request: request)
            user_query = extract_user_query(request: request)
            tags = derive_tags(query: user_query)
            metadata = request.respond_to?(:metadata) && request.metadata.is_a?(Hash) ? request.metadata : {}
            producer = metadata.slice(:context, :access_scope, :identity_principal_id, :identity_id, :identity_canonical_name,
                                      :source_agent, :source_provider, :source_model, :source_channel, :knowledge_domain)

            {
              content:               content,
              content_type:          'observation',
              tags:                  Legion::Extensions::Apollo::Helpers::TagNormalizer.normalize_all(tags),
              source_agent:          response.respond_to?(:model) ? response.model : 'unknown',
              source_model:          response.respond_to?(:model) ? response.model : nil,
              source_provider:       response.respond_to?(:provider) ? response.provider : nil,
              context:               {},
              identity_principal_id: nil,
              source_channel:        "#{source_channel || 'pipeline'}_synthesis",
              submitted_by:          caller_identity,
              submitted_from:        Socket.gethostname,
              knowledge_domain:      nil,
              content_hash:          content_hash(content: content)
            }.merge(producer)
          end

          def route_payload(payload:, **)
            if Legion::Extensions::Apollo::Helpers::Capability.can_embed?
              Legion::Extensions::Apollo::Runners::Writeback.handle_vectorize(**payload)
            else
              Legion::Extensions::Apollo::Runners::Writeback.writeback_deliver(payload: payload, has_embedding: false)
            end
          end

          def writeback_enabled?
            settings[:writeback][:enabled] != false
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.writeback.writeback_enabled')
            true
          end

          def min_content_length
            settings[:writeback][:min_content_length]
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.writeback.min_content_length')
            MIN_CONTENT_LENGTH
          end

          def content_hash(content:, **)
            normalized = content.to_s.strip.downcase.gsub(/\s+/, ' ')
            Digest::MD5.hexdigest(normalized)
          end

          def response_content(response:, **)
            msg = response.respond_to?(:message) ? response.message : nil
            return nil unless msg.is_a?(Hash)

            msg[:content] || msg['content']
          end

          def extract_identity(request:, **)
            return 'unknown' unless request.respond_to?(:caller) && request.caller.is_a?(Hash)

            request.caller.dig(:requested_by, :identity) || 'unknown'
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.writeback.extract_identity')
            'unknown'
          end

          def extract_user_query(request:, **)
            return '' unless request.respond_to?(:messages)

            user_msgs = Array(request.messages).select { |m| m[:role] == 'user' || m['role'] == 'user' }
            (user_msgs.last || {})[:content] || ''
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.writeback.extract_user_query')
            ''
          end

          def extract_tool_calls(response:, enrichments:, **)
            calls = []
            calls.concat(Array(response.tools)) if response.respond_to?(:tools)
            calls.concat(Array(response.tool_calls)) if response.respond_to?(:tool_calls)
            calls.concat(Array(enrichments['tool_calls'])) if enrichments['tool_calls']
            calls.uniq! { |call| call.respond_to?(:name) ? call.name : call[:name] || call['name'] }
            calls
          end

          def derive_tags(query:, **)
            stop_words = %w[a an the is are was were be been being have has had do does did will would shall
                            should may might can could of in to for on with at by from as into about between
                            how what when where why who which this that these those it its and or but not]
            words = query.to_s.downcase.gsub(/[^a-z0-9\s]/, '').split
            words.reject { |w| stop_words.include?(w) || w.length < 3 }
                 .uniq
                 .first(5)
          end
        end
      end
    end
  end
end
