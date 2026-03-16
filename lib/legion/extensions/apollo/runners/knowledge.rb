# frozen_string_literal: true

require_relative '../helpers/confidence'

module Legion
  module Extensions
    module Apollo
      module Runners
        module Knowledge
          def store_knowledge(content:, content_type:, tags: [], source_agent: nil, context: {}, **)
            content_type = content_type.to_sym
            unless Helpers::Confidence::CONTENT_TYPES.include?(content_type)
              raise ArgumentError, "invalid content_type: #{content_type}. Must be one of #{Helpers::Confidence::CONTENT_TYPES}"
            end

            {
              action:       :store,
              content:      content,
              content_type: content_type,
              tags:         Array(tags),
              source_agent: source_agent,
              context:      context
            }
          end

          def query_knowledge(query:, limit: 10, min_confidence: 0.3, status: [:confirmed], tags: nil, **)
            {
              action:         :query,
              query:          query,
              limit:          limit,
              min_confidence: min_confidence,
              status:         Array(status),
              tags:           tags
            }
          end

          def related_entries(entry_id:, relation_types: nil, depth: 2, **)
            {
              action:         :traverse,
              entry_id:       entry_id,
              relation_types: relation_types,
              depth:          depth
            }
          end

          def deprecate_entry(entry_id:, reason:, **)
            {
              action:   :deprecate,
              entry_id: entry_id,
              reason:   reason
            }
          end

          include Legion::Extensions::Helpers::Lex if defined?(Legion::Extensions::Helpers::Lex)
        end
      end
    end
  end
end
