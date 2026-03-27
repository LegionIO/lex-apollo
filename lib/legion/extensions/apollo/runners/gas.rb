# frozen_string_literal: true

module Legion
  module Extensions
    module Apollo
      module Runners
        module Gas
          RELATION_TYPES = %w[
            similar_to contradicts depends_on causes
            part_of supersedes supports_by extends
          ].freeze

          RELATE_CONFIDENCE_GATE = 0.7
          SYNTHESIS_CONFIDENCE_CAP = 0.7
          MAX_ANTICIPATIONS = 3

          module_function

          def relate_confidence_gate = Helpers::Confidence.apollo_setting(:gas, :relate_confidence_gate, default: RELATE_CONFIDENCE_GATE)
          def synthesis_confidence_cap = Helpers::Confidence.apollo_setting(:gas, :synthesis_confidence_cap, default: SYNTHESIS_CONFIDENCE_CAP)
          def max_anticipations       = Helpers::Confidence.apollo_setting(:gas, :max_anticipations, default: MAX_ANTICIPATIONS)
          def similar_entries_limit   = Helpers::Confidence.apollo_setting(:gas, :similar_entries_limit, default: 3)
          def fallback_confidence     = Helpers::Confidence.apollo_setting(:gas, :fallback_confidence, default: 0.5)

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
              facts:            facts.length,
              entities:         entities.length,
              relations:        relations.length,
              synthesis:        synthesis.length,
              deposited:        deposit_result,
              anticipations:    anticipations.length
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
          rescue StandardError => e
            Legion::Logging.warn("GAS phase_extract failed: #{e.message}") if defined?(Legion::Logging)
            []
          end

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
          def phase_synthesize(facts, _relations)
            return [] if facts.length < 2
            return [] unless llm_available?

            llm_synthesize(facts)
          rescue StandardError => e
            Legion::Logging.warn("GAS phase_synthesize failed: #{e.message}") if defined?(Legion::Logging)
            []
          end

          # Phase 5: Deposit - atomic write to Apollo
          def phase_deposit(facts, _entities, _relations, _synthesis, audit_event)
            return { deposited: 0 } unless defined?(Runners::Knowledge)

            deposited = 0
            facts.each do |fact|
              Runners::Knowledge.handle_ingest(
                content:          fact[:content],
                content_type:     fact[:content_type].to_s,
                tags:             %w[gas auto_extracted],
                source_agent:     'gas_pipeline',
                source_provider:  audit_event.dig(:routing, :provider)&.to_s,
                knowledge_domain: 'general',
                context:          { source_request_id: audit_event[:request_id] }
              )
              deposited += 1
            rescue StandardError => e
              Legion::Logging.warn("GAS deposit error: #{e.message}") if defined?(Legion::Logging)
            end
            { deposited: deposited }
          end

          # Phase 6: Anticipate - pre-cache likely follow-up questions
          def phase_anticipate(facts, _synthesis)
            return [] if facts.empty?
            return [] unless llm_available?

            llm_anticipate(facts)
          rescue StandardError => e
            Legion::Logging.warn("GAS phase_anticipate failed: #{e.message}") if defined?(Legion::Logging)
            []
          end

          def fetch_similar_entries(facts)
            lim = similar_entries_limit
            min_conf = Helpers::GraphQuery.default_query_min_confidence
            entries = []
            facts.each do |fact|
              result = Runners::Knowledge.retrieve_relevant(query: fact[:content], limit: lim, min_confidence: min_conf)
              entries.concat(result[:entries]) if result[:success] && result[:entries]&.any?
            rescue StandardError => e
              Legion::Logging.warn("GAS fetch_similar_entries failed for fact: #{e.message}") if defined?(Legion::Logging)
              next
            end
            entries.uniq { |e| e[:id] }
          end

          def classify_relation(fact, entry)
            fb_conf = fallback_confidence
            if llm_available?
              llm_classify_relation(fact, entry)
            else
              { from_content: fact[:content], to_id: entry[:id], relation_type: 'similar_to', confidence: fb_conf }
            end
          rescue StandardError => e
            Legion::Logging.warn("GAS classify_relation failed: #{e.message}") if defined?(Legion::Logging)
            { from_content: fact[:content], to_id: entry[:id], relation_type: 'similar_to', confidence: fallback_confidence }
          end

          def llm_classify_relation(fact, entry) # rubocop:disable Metrics/CyclomaticComplexity
            prompt = <<~PROMPT
              Classify the relationship between these two knowledge entries.
              Valid types: #{RELATION_TYPES.join(', ')}

              Entry A (new): #{fact[:content]}
              Entry B (existing): #{entry[:content]}

              Return JSON with relation_type and confidence (0.0-1.0).
            PROMPT

            result = Legion::LLM::Pipeline::GaiaCaller.structured(
              message: prompt.strip,
              schema:  {
                type:       :object,
                properties: {
                  relations: {
                    type:  :array,
                    items: {
                      type:       :object,
                      properties: {
                        relation_type: { type: :string },
                        confidence:    { type: :number }
                      },
                      required:   %w[relation_type confidence]
                    }
                  }
                },
                required:   ['relations']
              },
              phase:   'gas_relate'
            )

            content = result.respond_to?(:message) ? result.message[:content] : result.to_s
            parsed = Legion::JSON.load(content)
            rels = parsed.is_a?(Hash) ? (parsed[:relations] || parsed['relations'] || []) : []
            best = rels.max_by { |r| r[:confidence] || r['confidence'] || 0 }

            return fallback_relation(fact, entry) unless best

            conf = best[:confidence] || best['confidence'] || 0
            rtype = best[:relation_type] || best['relation_type']
            return fallback_relation(fact, entry) if conf < relate_confidence_gate || !RELATION_TYPES.include?(rtype)

            { from_content: fact[:content], to_id: entry[:id], relation_type: rtype, confidence: conf }
          rescue StandardError => e
            Legion::Logging.warn("GAS llm_classify_relation failed: #{e.message}") if defined?(Legion::Logging)
            fallback_relation(fact, entry)
          end

          def fallback_relation(fact, entry)
            { from_content: fact[:content], to_id: entry[:id], relation_type: 'similar_to', confidence: fallback_confidence }
          end

          def llm_synthesize(facts)
            facts_text = facts.each_with_index.map { |f, i| "[#{i}] (#{f[:content_type]}) #{f[:content]}" }.join("\n")

            prompt = <<~PROMPT
              Given these knowledge entries, generate derivative insights (inferences, implications, or connections).
              Each synthesis should combine information from multiple sources.

              Entries:
              #{facts_text}

              Return JSON with a "synthesis" array where each item has: content (string), content_type (inference/implication/connection), source_indices (array of entry indices used).
            PROMPT

            result = Legion::LLM::Pipeline::GaiaCaller.structured(
              message: prompt.strip,
              schema:  {
                type:       :object,
                properties: {
                  synthesis: {
                    type:  :array,
                    items: {
                      type:       :object,
                      properties: {
                        content:        { type: :string },
                        content_type:   { type: :string },
                        source_indices: { type: :array, items: { type: :integer } }
                      },
                      required:   %w[content content_type source_indices]
                    }
                  }
                },
                required:   ['synthesis']
              },
              phase:   'gas_synthesize'
            )

            content = result.respond_to?(:message) ? result.message[:content] : result.to_s
            parsed = Legion::JSON.load(content)
            items = parsed.is_a?(Hash) ? (parsed[:synthesis] || parsed['synthesis'] || []) : []

            items.map { |item| build_synthesis_entry(item, facts) }
          rescue StandardError => e
            Legion::Logging.warn("GAS llm_synthesize failed: #{e.message}") if defined?(Legion::Logging)
            []
          end

          def build_synthesis_entry(item, facts)
            source_indices = item[:source_indices] || item['source_indices'] || []
            source_confs = source_indices.filter_map { |i| facts[i]&.dig(:confidence) }
            fb = fallback_confidence
            geo_mean = source_confs.empty? ? fb : geometric_mean(source_confs)

            {
              content:        item[:content] || item['content'],
              content_type:   (item[:content_type] || item['content_type'] || 'inference').to_sym,
              status:         :candidate,
              confidence:     [geo_mean, synthesis_confidence_cap].min,
              source_indices: source_indices
            }
          end

          def geometric_mean(values)
            return 0.0 if values.empty?

            product = values.reduce(1.0) { |acc, v| acc * v }
            product**(1.0 / values.length)
          end

          def llm_anticipate(facts)
            facts_text = facts.map { |f| "(#{f[:content_type]}) #{f[:content]}" }.join("\n")

            prompt = <<~PROMPT
              Given these knowledge entries, generate 1-3 likely follow-up questions a user might ask.

              Knowledge:
              #{facts_text}

              Return JSON with a "questions" array of question strings.
            PROMPT

            result = Legion::LLM::Pipeline::GaiaCaller.structured(
              message: prompt.strip,
              schema:  {
                type:       :object,
                properties: {
                  questions: { type: :array, items: { type: :string } }
                },
                required:   ['questions']
              },
              phase:   'gas_anticipate'
            )

            content = result.respond_to?(:message) ? result.message[:content] : result.to_s
            parsed = Legion::JSON.load(content)
            questions = parsed.is_a?(Hash) ? (parsed[:questions] || parsed['questions'] || []) : []
            questions = questions.first(max_anticipations)

            questions.map do |q|
              promote_to_pattern_store(question: q, facts: facts)
              { question: q }
            end
          rescue StandardError => e
            Legion::Logging.warn("GAS llm_anticipate failed: #{e.message}") if defined?(Legion::Logging)
            []
          end

          def promote_to_pattern_store(question:, facts:)
            return unless defined?(Legion::Extensions::Agentic::TBI::PatternStore)

            Legion::Extensions::Agentic::TBI::PatternStore.promote_candidate(
              intent:     question,
              resolution: { source: 'gas_anticipate', facts: facts.map { |f| f[:content] } },
              confidence: fallback_confidence
            )
          rescue StandardError => e
            Legion::Logging.warn("GAS promote_to_pattern_store failed: #{e.message}") if defined?(Legion::Logging)
            nil
          end

          def llm_available?
            defined?(Legion::LLM::Pipeline::GaiaCaller)
          rescue StandardError => e
            Legion::Logging.warn("GAS llm_available? check failed: #{e.message}") if defined?(Legion::Logging)
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
              schema:  {
                type:       :object,
                properties: {
                  facts: {
                    type:  :array,
                    items: {
                      type:       :object,
                      properties: {
                        content:      { type: :string },
                        content_type: { type: :string }
                      },
                      required:   %w[content content_type]
                    }
                  }
                },
                required:   ['facts']
              },
              phase:   'gas_comprehend'
            )

            content = result.respond_to?(:message) ? result.message[:content] : result.to_s
            parsed = Legion::JSON.load(content)
            facts_array = parsed.is_a?(Hash) ? (parsed[:facts] || parsed['facts'] || []) : Array(parsed)
            facts_array.map do |f|
              {
                content:      f[:content] || f['content'],
                content_type: (f[:content_type] || f['content_type'] || 'fact').to_sym
              }
            end
          rescue StandardError => e
            Legion::Logging.warn("GAS llm_comprehend failed: #{e.message}") if defined?(Legion::Logging)
            mechanical_comprehend(messages, response)
          end
        end
      end
    end
  end
end
