# frozen_string_literal: true

module Legion
  module Extensions
    module Apollo
      module Runners
        module EntityExtractor
          DEFAULT_ENTITY_TYPES = %w[person service repository concept].freeze
          DEFAULT_MIN_CONFIDENCE = 0.7

          def extract_entities(text:, entity_types: nil, min_confidence: DEFAULT_MIN_CONFIDENCE, **)
            return { success: true, entities: [], source: :empty } if text.to_s.strip.empty?

            return { success: true, entities: [], source: :unavailable } unless defined?(Legion::LLM) && Legion::LLM.started?

            types = Array(entity_types).map(&:to_s)
            types = DEFAULT_ENTITY_TYPES if types.empty?

            result = Legion::LLM.structured(
              messages: [
                { role: 'user', content: entity_extraction_prompt(text: text, entity_types: types) }
              ],
              schema:   entity_schema,
              caller:   { extension: 'lex-apollo', runner: 'entity_extractor' }
            )

            raw_entities = result.dig(:data, :entities) || []
            filtered = raw_entities.select do |entity|
              (entity[:confidence] || 0.0) >= min_confidence &&
                (types.empty? || types.include?(entity[:type].to_s))
            end

            { success: true, entities: filtered, source: :llm }
          rescue StandardError => e
            { success: false, entities: [], error: e.message, source: :error }
          end

          def entity_extraction_prompt(text:, entity_types:, **)
            type_list = Array(entity_types).join(', ')
            <<~PROMPT.strip
              Extract named entities from the following text. Return only entities of these types: #{type_list}.

              For each entity provide:
              - name: the canonical name as it appears (string)
              - type: one of #{type_list} (string)
              - confidence: your confidence this is a real entity of that type (float 0.0-1.0)

              Text:
              #{text}
            PROMPT
          end

          def entity_schema
            {
              type:       'object',
              properties: {
                entities: {
                  type:  'array',
                  items: {
                    type:       'object',
                    properties: {
                      name:       { type: 'string' },
                      type:       { type: 'string' },
                      confidence: { type: 'number' }
                    },
                    required:   %w[name type confidence]
                  }
                }
              },
              required:   ['entities']
            }
          end
        end
      end
    end
  end
end
