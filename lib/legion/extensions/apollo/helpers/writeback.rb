# frozen_string_literal: true

require 'digest'
require 'socket'

module Legion
  module Extensions
    module Apollo
      module Helpers
        module Writeback
          RESEARCH_TOOLS = %w[read_file search_files search_content run_command].freeze
          MAX_CONTENT_LENGTH = 4000
          MIN_CONTENT_LENGTH = 50

          module_function

          def evaluate_and_route(request:, response:, enrichments: {})
            return unless writeback_enabled?
            return unless should_capture?(request, response, enrichments)

            payload = build_payload(request: request, response: response)
            route_payload(payload)
          rescue StandardError => e
            Legion::Logging.warn("apollo writeback failed: #{e.message}") if defined?(Legion::Logging)
          end

          def should_capture?(_request, response, enrichments)
            content = response_content(response)
            return false if content.nil? || content.length < min_content_length

            tool_calls = extract_tool_calls(response, enrichments)
            research_calls = tool_calls.select { |tc| RESEARCH_TOOLS.include?(tc[:name] || tc['name']) }

            return false if research_calls.empty?

            apollo_results = enrichments['rag_context:apollo_results']
            return true if apollo_results.nil? || (apollo_results[:count] || 0).zero?

            # Apollo had results — only capture if LLM also did additional research
            research_calls.any?
          end

          def build_payload(request:, response:, source_channel: nil)
            content = response_content(response)
            caller_identity = extract_identity(request)
            user_query = extract_user_query(request)
            tags = derive_tags(user_query)

            {
              content:          content[0...MAX_CONTENT_LENGTH],
              content_type:     'observation',
              tags:             Helpers::TagNormalizer.normalize_all(tags),
              source_agent:     response.respond_to?(:model) ? response.model : 'unknown',
              source_channel:   "#{source_channel || 'pipeline'}_synthesis",
              submitted_by:     caller_identity,
              submitted_from:   Socket.gethostname,
              knowledge_domain: nil,
              content_hash:     content_hash(content)
            }
          end

          def route_payload(payload)
            can_embed = Helpers::Capability.can_embed?
            can_write = Helpers::Capability.can_write?

            if can_embed
              result = Legion::LLM::Embeddings.generate(text: payload[:content])
              vector = result.is_a?(Hash) ? result[:vector] : result
              payload[:embedding] = vector.is_a?(Array) && vector.any? ? vector : Array.new(1024, 0.0)
            end

            if can_write && can_embed
              write_directly(payload)
            else
              publish_to_transport(payload, has_embedding: can_embed)
            end
          end

          def write_directly(payload)
            if defined?(Legion::Apollo)
              Legion::Apollo.ingest(**payload)
            else
              Runners::Knowledge.handle_ingest(**payload)
            end
          rescue StandardError => e
            Legion::Logging.warn("apollo direct write failed, falling back to transport: #{e.message}") if defined?(Legion::Logging)
            publish_to_transport(payload, has_embedding: !payload[:embedding].nil?)
          end

          def publish_to_transport(payload, has_embedding: false)
            return unless defined?(Legion::Transport)

            Transport::Messages::Writeback.new(
              **payload, has_embedding: has_embedding
            ).publish
          rescue StandardError => e
            Legion::Logging.warn("apollo writeback publish failed: #{e.message}") if defined?(Legion::Logging)
          end

          def writeback_enabled?
            Legion::Settings.dig(:apollo, :writeback, :enabled) != false
          rescue StandardError => e
            Legion::Logging.warn("Apollo Writeback.writeback_enabled? failed: #{e.message}") if defined?(Legion::Logging)
            true
          end

          def min_content_length
            Legion::Settings.dig(:apollo, :writeback, :min_content_length) || MIN_CONTENT_LENGTH
          rescue StandardError => e
            Legion::Logging.warn("Apollo Writeback.min_content_length failed: #{e.message}") if defined?(Legion::Logging)
            MIN_CONTENT_LENGTH
          end

          def content_hash(content)
            normalized = content.to_s.strip.downcase.gsub(/\s+/, ' ')
            Digest::MD5.hexdigest(normalized)
          end

          def response_content(response)
            msg = response.respond_to?(:message) ? response.message : nil
            return nil unless msg.is_a?(Hash)

            msg[:content] || msg['content']
          end

          def extract_identity(request)
            return 'unknown' unless request.respond_to?(:caller) && request.caller.is_a?(Hash)

            request.caller.dig(:requested_by, :identity) || 'unknown'
          rescue StandardError => e
            Legion::Logging.warn("Apollo Writeback.extract_identity failed: #{e.message}") if defined?(Legion::Logging)
            'unknown'
          end

          def extract_user_query(request)
            return '' unless request.respond_to?(:messages)

            user_msgs = Array(request.messages).select { |m| m[:role] == 'user' || m['role'] == 'user' }
            (user_msgs.last || {})[:content] || ''
          rescue StandardError => e
            Legion::Logging.warn("Apollo Writeback.extract_user_query failed: #{e.message}") if defined?(Legion::Logging)
            ''
          end

          def extract_tool_calls(response, enrichments)
            calls = []
            calls += Array(response.tool_calls) if response.respond_to?(:tool_calls)
            calls += Array(enrichments['tool_calls']) if enrichments['tool_calls']
            calls.uniq { |tc| tc[:name] || tc['name'] }
          end

          def derive_tags(query)
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
