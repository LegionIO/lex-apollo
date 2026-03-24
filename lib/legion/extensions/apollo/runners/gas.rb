# frozen_string_literal: true

module Legion
  module Extensions
    module Apollo
      module Runners
        module Gas
          module_function

          def process(audit_event)
            return { phases_completed: 0, reason: 'no content' } unless processable?(audit_event)

            facts = phase_comprehend(audit_event)
            entities = phase_extract(audit_event, facts)
            relations = phase_relate(facts, entities)
            synthesis = phase_synthesize(facts, relations)
            deposit_result = phase_deposit(facts, entities, relations, synthesis, audit_event)
            anticipations = phase_anticipate(facts, synthesis)

            {
              phases_completed: 6,
              facts: facts.length,
              entities: entities.length,
              relations: relations.length,
              synthesis: synthesis.length,
              deposited: deposit_result,
              anticipations: anticipations.length
            }
          rescue StandardError => e
            Legion::Logging.warn("GAS pipeline error: #{e.message}") if defined?(Legion::Logging)
            { phases_completed: 0, error: e.message }
          end

          def processable?(event)
            event[:messages]&.any? == true && !event[:response_content].nil?
          end

          # Phase 1: Comprehend - extract typed facts from the exchange
          def phase_comprehend(audit_event)
            messages = audit_event[:messages]
            response = audit_event[:response_content]

            if llm_available?
              llm_comprehend(messages, response)
            else
              mechanical_comprehend(messages, response)
            end
          end

          # Phase 2: Extract - entity extraction (delegates to existing EntityExtractor)
          def phase_extract(audit_event, _facts)
            return [] unless defined?(Runners::EntityExtractor)

            result = Runners::EntityExtractor.extract_entities(text: audit_event[:response_content])
            result[:success] ? (result[:entities] || []) : []
          rescue StandardError
            []
          end

          RELATION_TYPES = %w[
            similar_to contradicts depends_on causes
            part_of supersedes supports_by extends
          ].freeze

          RELATE_CONFIDENCE_GATE = 0.7

          # Phase 3: Relate - classify relationships between new and existing entries
          def phase_relate(facts, _entities)
            return [] unless defined?(Runners::Knowledge)

            existing = fetch_similar_entries(facts)
            return [] if existing.empty?

            relations = []
            facts.each do |fact|
              existing.each do |entry|
                relation = classify_relation(fact, entry)
                relations << relation if relation
              end
            end
            relations
          end

          # Phase 4: Synthesize - generate derivative knowledge
          def phase_synthesize(_facts, _relations)
            []
          end

          # Phase 5: Deposit - atomic write to Apollo
          def phase_deposit(facts, _entities, _relations, _synthesis, audit_event)
            return { deposited: 0 } unless defined?(Runners::Knowledge)

            deposited = 0
            facts.each do |fact|
              Runners::Knowledge.handle_ingest(
                content: fact[:content],
                content_type: fact[:content_type].to_s,
                tags: %w[gas auto_extracted],
                source_agent: 'gas_pipeline',
                source_provider: audit_event.dig(:routing, :provider)&.to_s,
                knowledge_domain: 'general',
                context: { source_request_id: audit_event[:request_id] }
              )
              deposited += 1
            rescue StandardError => e
              Legion::Logging.warn("GAS deposit error: #{e.message}") if defined?(Legion::Logging)
            end
            { deposited: deposited }
          end

          # Phase 6: Anticipate - pre-cache likely follow-up questions
          def phase_anticipate(_facts, _synthesis)
            []
          end

          def fetch_similar_entries(facts)
            entries = []
            facts.each do |fact|
              result = Runners::Knowledge.retrieve_relevant(query: fact[:content], limit: 3, min_confidence: 0.3)
              entries.concat(result[:entries]) if result[:success] && result[:entries]&.any?
            rescue StandardError
              next
            end
            entries.uniq { |e| e[:id] }
          end

          def classify_relation(fact, entry)
            if llm_available?
              llm_classify_relation(fact, entry)
            else
              { from_content: fact[:content], to_id: entry[:id], relation_type: 'similar_to', confidence: 0.5 }
            end
          rescue StandardError
            { from_content: fact[:content], to_id: entry[:id], relation_type: 'similar_to', confidence: 0.5 }
          end

          def llm_classify_relation(fact, entry)
            prompt = <<~PROMPT
              Classify the relationship between these two knowledge entries.
              Valid types: #{RELATION_TYPES.join(', ')}

              Entry A (new): #{fact[:content]}
              Entry B (existing): #{entry[:content]}

              Return JSON with relation_type and confidence (0.0-1.0).
            PROMPT

            result = Legion::LLM::Pipeline::GaiaCaller.structured(
              message: prompt.strip,
              schema: {
                type: :object,
                properties: {
                  relations: {
                    type: :array,
                    items: {
                      type: :object,
                      properties: {
                        relation_type: { type: :string },
                        confidence: { type: :number }
                      },
                      required: %w[relation_type confidence]
                    }
                  }
                },
                required: ['relations']
              },
              phase: 'gas_relate'
            )

            content = result.respond_to?(:message) ? result.message[:content] : result.to_s
            parsed = Legion::JSON.load(content)
            rels = parsed.is_a?(Hash) ? (parsed[:relations] || parsed['relations'] || []) : []
            best = rels.max_by { |r| r[:confidence] || r['confidence'] || 0 }

            return fallback_relation(fact, entry) unless best

            conf = best[:confidence] || best['confidence'] || 0
            rtype = best[:relation_type] || best['relation_type']
            return fallback_relation(fact, entry) if conf < RELATE_CONFIDENCE_GATE || !RELATION_TYPES.include?(rtype)

            { from_content: fact[:content], to_id: entry[:id], relation_type: rtype, confidence: conf }
          rescue StandardError
            fallback_relation(fact, entry)
          end

          def fallback_relation(fact, entry)
            { from_content: fact[:content], to_id: entry[:id], relation_type: 'similar_to', confidence: 0.5 }
          end

          def llm_available?
            defined?(Legion::LLM::Pipeline::GaiaCaller)
          rescue StandardError
            false
          end

          def mechanical_comprehend(_messages, response)
            [{ content: response, content_type: :observation }]
          end

          def llm_comprehend(messages, response)
            prompt = <<~PROMPT
              Extract distinct facts from this exchange. Return JSON array of {content:, content_type:} where content_type is one of: fact, concept, procedure, association.

              User: #{messages.last&.dig(:content)}
              Assistant: #{response}
            PROMPT

            result = Legion::LLM::Pipeline::GaiaCaller.structured(
              message: prompt.strip,
              schema: {
                type: :object,
                properties: {
                  facts: {
                    type: :array,
                    items: {
                      type: :object,
                      properties: {
                        content: { type: :string },
                        content_type: { type: :string }
                      },
                      required: %w[content content_type]
                    }
                  }
                },
                required: ['facts']
              },
              phase: 'gas_comprehend'
            )

            content = result.respond_to?(:message) ? result.message[:content] : result.to_s
            parsed = Legion::JSON.load(content)
            facts_array = parsed.is_a?(Hash) ? (parsed[:facts] || parsed['facts'] || []) : Array(parsed)
            facts_array.map do |f|
              {
                content: f[:content] || f['content'],
                content_type: (f[:content_type] || f['content_type'] || 'fact').to_sym
              }
            end
          rescue StandardError
            mechanical_comprehend(messages, response)
          end
        end
      end
    end
  end
end
