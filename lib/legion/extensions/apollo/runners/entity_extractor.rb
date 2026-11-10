# frozen_string_literal: true

require 'legion/llm'
require 'legion/logging/helper'
require 'legion/settings/helper'

module Legion
  module Extensions
    module Apollo
      module Runners
        module EntityExtractor
          include Legion::Logging::Helper
          include Legion::Settings::Helper
          extend self

          def extract_entities(text:, entity_types: nil, min_confidence: Legion::Extensions::Apollo.settings[:entity_extractor][:min_confidence], **)
            if text.to_s.strip.empty?
              log.debug('Apollo EntityExtractor.extract_entities skipped reason=empty_text')
              return { success: true, entities: [], source: :empty }
            end

            unless Legion::LLM.started?
              log.debug('Apollo EntityExtractor.extract_entities skipped reason=llm_unavailable')
              return { success: true, entities: [], source: :unavailable }
            end

            types = Array(entity_types).map(&:to_s)
            types = Legion::Extensions::Apollo.settings[:entity_extractor][:types].map(&:to_s) if types.empty?
            log.debug("Apollo EntityExtractor.extract_entities text_length=#{text.to_s.length} types=#{types.join(',')} min_confidence=#{min_confidence}")

            result = Legion::LLM.structured(
              messages: [
                { role: 'user', content: entity_extractor_prompt(text: text, entity_types: types) }
              ],
              schema:   entity_extractor_schema,
              caller:   { extension: 'lex-apollo', runner: 'entity_extractor' }
            )

            raw_entities = result.dig(:data, :entities) || []
            filtered = raw_entities.select do |entity|
              (entity[:confidence] || 0.0) >= min_confidence &&
                (types.empty? || types.include?(entity[:type].to_s))
            end
            log.info("Apollo EntityExtractor.extract_entities raw=#{raw_entities.size} filtered=#{filtered.size}")

            { success: true, entities: filtered, source: :llm }
          rescue ArgumentError, NameError, TypeError => e
            handle_exception(e, level: :error, operation: 'apollo.entity_extractor.extract_entities')
            raise
          rescue StandardError => e
            handle_exception(e, level: :error, operation: 'apollo.entity_extractor.extract_entities')
            { success: false, entities: [], error: e.message, source: :error }
          end

          private

          def entity_extractor_prompt(text:, entity_types:, **)
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

          def entity_extractor_schema
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
