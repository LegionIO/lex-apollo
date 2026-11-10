# frozen_string_literal: true

require 'digest'
require 'socket'
require 'legion/logging/helper'
require 'legion/settings/helper'
require 'legion/extensions/apollo/helpers/capability'
require 'legion/extensions/apollo/helpers/tag_normalizer'
require 'legion/extensions/apollo/runners/writeback'

module Legion
  module Extensions
    module Apollo
      module Helpers
        module Writeback
          include Legion::Logging::Helper
          include Legion::Settings::Helper
          include Legion::Extensions::Apollo::Helpers::Capability
          include Legion::Extensions::Apollo::Helpers::TagNormalizer
          extend self

          RESEARCH_TOOLS = %w[read_file search_files search_content run_command].freeze

          def evaluate_and_route(request:, response:, enrichments: {}, **)
            return { success: true, skipped: true, reason: :disabled } if settings[:writeback][:enabled] == false
            return { success: true, skipped: true, reason: :not_research } unless writeback_should_capture?(response: response, enrichments: enrichments)

            payload = writeback_build_payload(request: request, response: response)
            writeback_route_payload(payload: payload)
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.writeback.evaluate_and_route')
            raise
          end

          def content_hash(content:, **)
            normalized = content.to_s.strip.downcase.gsub(/\s+/, ' ')
            Digest::MD5.hexdigest(normalized)
          end

          private

          def writeback_should_capture?(response:, enrichments:, **)
            content = writeback_response_content(response: response)
            return false if content.nil? || content.length < settings[:writeback][:min_content_length]

            writeback_extract_tool_calls(response: response, enrichments: enrichments).any? do |call|
              name = call.respond_to?(:name) ? call.name : call[:name] || call['name']
              RESEARCH_TOOLS.include?(name)
            end
          end

          def writeback_build_payload(request:, response:, source_channel: nil, **)
            content = writeback_response_content(response: response)[0...settings[:writeback][:max_content_length]]
            caller_identity = writeback_extract_identity(request: request)
            user_query = writeback_extract_user_query(request: request)
            metadata = request.respond_to?(:metadata) && request.metadata.is_a?(Hash) ? request.metadata : {}
            producer = metadata.slice(:context, :access_scope, :identity_principal_id, :identity_id, :identity_canonical_name,
                                      :source_agent, :source_provider, :source_model, :source_channel, :knowledge_domain)

            {
              content:               content,
              content_type:          'observation',
              tags:                  tag_normalize_all(tags: writeback_derive_tags(query: user_query)),
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

          def writeback_route_payload(payload:, **)
            if capability_can_embed?
              Legion::Extensions::Apollo::Runners::Writeback.handle_vectorize(**payload)
            else
              Legion::Extensions::Apollo::Runners::Writeback.writeback_deliver(payload: payload, has_embedding: false)
            end
          end

          def writeback_response_content(response:, **)
            msg = response.respond_to?(:message) ? response.message : nil
            return nil unless msg.is_a?(Hash)

            msg[:content] || msg['content']
          end

          def writeback_extract_identity(request:, **)
            return 'unknown' unless request.respond_to?(:caller) && request.caller.is_a?(Hash)

            request.caller.dig(:requested_by, :identity) || 'unknown'
          end

          def writeback_extract_user_query(request:, **)
            return '' unless request.respond_to?(:messages)

            user_msgs = Array(request.messages).select { |m| m[:role] == 'user' || m['role'] == 'user' }
            last = user_msgs.last || {}
            last[:content] || last['content'] || ''
          end

          def writeback_extract_tool_calls(response:, enrichments:, **)
            calls = []
            calls.concat(Array(response.tools)) if response.respond_to?(:tools)
            calls.concat(Array(response.tool_calls)) if response.respond_to?(:tool_calls)
            calls.concat(Array(enrichments[:tool_calls] || enrichments['tool_calls']))
            calls.uniq { |call| call.respond_to?(:name) ? call.name : call[:name] || call['name'] }
          end

          def writeback_derive_tags(query:, **)
            stop_words = %w[a an the is are was were be been being have has had do does did will would shall
                            should may might can could of in to for on with at by from as into about between
                            how what when where why who which this that these those it its and or but not]
            query.to_s.downcase.gsub(/[^a-z0-9\s]/, '').split
                 .reject { |word| stop_words.include?(word) || word.length < 3 }
                 .uniq.first(5)
          end
        end
      end
    end
  end
end
