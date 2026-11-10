# frozen_string_literal: true

require 'legion/llm/inference'
require 'legion/logging/helper'
require 'legion/settings/helper'
require 'legion/json'
require 'legion/extensions/apollo/helpers/data_models'
require 'legion/extensions/apollo/runners/entity_extractor'
require 'legion/extensions/apollo/runners/knowledge'

module Legion
  module Extensions
    module Apollo
      module Runners
        module Gas
          include Legion::Logging::Helper
          include Legion::JSON::Helper
          include Legion::Settings::Helper
          extend Legion::Extensions::Apollo::Helpers::DataModels

          RELATION_TYPES = %w[
            similar_to contradicts depends_on causes
            part_of supersedes supports_by extends
          ].freeze

          extend self

          def process(**audit_event)
            unless gas_processable?(audit_event)
              log.debug('GAS process skipped reason=no_content')
              return { success: true, phases_completed: 0, reason: 'no content' }
            end

            log.debug("GAS process start request_id=#{audit_event[:request_id] || 'nil'} messages=#{Array(audit_event[:messages]).size} response_length=#{audit_event[:response_content].to_s.length}") # rubocop:disable Layout/LineLength

            facts = gas_phase_comprehend(audit_event)
            entities = gas_phase_extract(audit_event, facts)
            relations = gas_phase_relate(facts: facts)
            synthesis = gas_phase_synthesize(facts, relations)
            deposit_result = gas_phase_deposit(facts: facts, relations: relations, synthesis: synthesis, audit_event: audit_event)
            anticipations = gas_phase_anticipate(facts, synthesis)

            result = {
              success:          deposit_result[:failed].zero? && deposit_result[:relations_failed].zero?,
              phases_completed: 6,
              facts:            facts.length,
              entities:         entities.length,
              relations:        relations.length,
              synthesis:        synthesis.length,
              deposited:        deposit_result,
              anticipations:    anticipations.length
            }
            log.info("GAS process complete facts=#{result[:facts]} entities=#{result[:entities]} relations=#{result[:relations]} synthesis=#{result[:synthesis]} anticipations=#{result[:anticipations]}") # rubocop:disable Layout/LineLength
            result
          rescue StandardError => e
            handle_exception(e, level: :error, operation: 'apollo.gas.process')
            { success: false, phases_completed: 0, error: e.message }
          end

          private

          def gas_processable?(event)
            event[:messages]&.any? == true && !event[:response_content].nil?
          end

          # Phase 1: Comprehend - extract typed facts from the exchange
          def gas_phase_comprehend(audit_event)
            messages = audit_event[:messages]
            response = audit_event[:response_content]

            mode = Legion::LLM.started? ? :llm : :mechanical
            log.debug("GAS phase_comprehend mode=#{mode} messages=#{Array(messages).size} response_length=#{response.to_s.length}")
            facts = mode == :llm ? gas_llm_comprehend(messages, response) : gas_mechanical_comprehend(messages, response)
            log.debug("GAS phase_comprehend facts=#{facts.size}")
            facts
          end

          # Phase 2: Extract - entity extraction (delegates to existing EntityExtractor)
          def gas_phase_extract(audit_event, _facts)
            result = Legion::Extensions::Apollo::Runners::EntityExtractor.extract_entities(text: audit_event[:response_content])
            raise IOError, "Apollo entity extraction failed: #{result[:error]}" unless result[:success]

            entities = result[:entities]
            log.debug("GAS phase_extract success=#{result[:success]} entities=#{entities.size}")
            entities
          end

          # Phase 3: Relate - classify relationships between new and existing entries
          def gas_phase_relate(facts:, **)
            existing = gas_fetch_similar_entries(facts: facts)
            if existing.empty?
              log.debug("GAS phase_relate skipped reason=no_existing_entries facts=#{facts.size}")
              return []
            end

            relations = []
            facts.each do |fact|
              existing.each do |entry|
                relation = gas_classify_relation(fact, entry)
                relations << relation if relation
              end
            end
            log.debug("GAS phase_relate facts=#{facts.size} existing=#{existing.size} relations=#{relations.size}")
            relations
          end

          # Phase 4: Synthesize - generate derivative knowledge
          def gas_phase_synthesize(facts, _relations)
            if facts.length < 2
              log.debug("GAS phase_synthesize skipped reason=insufficient_facts facts=#{facts.length}")
              return []
            end
            unless Legion::LLM.started?
              log.debug('GAS phase_synthesize skipped reason=llm_unavailable')
              return []
            end

            synthesis = gas_llm_synthesize(facts)
            log.debug("GAS phase_synthesize synthesis=#{synthesis.size}")
            synthesis
          end

          # Phase 5: Deposit entries, then link successfully stored facts.
          def gas_phase_deposit(facts:, relations:, synthesis:, audit_event:, **)
            counts = { deposited: 0, failed: 0, facts: 0, synthesis: 0 }
            fact_ids = Array.new(facts.size)
            source_ids = {}
            { facts: facts, synthesis: synthesis }.each do |kind, entries|
              entries.each_with_index do |item, index|
                context = { source_request_id: audit_event[:request_id] }
                if kind == :synthesis
                  context[:source_indices] = Array(item[:source_indices])
                  context[:source_entry_ids] = context[:source_indices].filter_map do |source_index|
                    fact_ids[source_index] if source_index.is_a?(Integer) && source_index.between?(0, facts.size - 1)
                  end.uniq
                end
                result = Legion::Extensions::Apollo::Runners::Knowledge.handle_ingest(
                  content: item[:content], content_type: item[:content_type].to_s,
                  tags: %w[gas auto_extracted], source_agent: 'gas_pipeline',
                  source_provider: audit_event.dig(:routing, :provider),
                  knowledge_domain: 'general', context: context
                )
                unless result.is_a?(Hash) && result[:success] == true && result[:entry_id]
                  counts[:failed] += 1
                  next
                end

                counts[:deposited] += 1
                counts[kind] += 1
                next unless kind == :facts

                fact_ids[index] = result[:entry_id]
                ids = (source_ids[item[:content]] ||= [])
                ids << result[:entry_id] unless ids.include?(result[:entry_id])
              rescue StandardError => e
                counts[:failed] += 1
                handle_exception(e, level: :warn, operation: 'apollo.gas.phase_deposit_entry')
              end
            end
            counts.merge!(gas_deposit_relations(relations: relations, source_ids: source_ids))
            log.info("GAS phase_deposit deposited=#{counts[:deposited]} failed=#{counts[:failed]} relations=#{counts[:relations]} relations_failed=#{counts[:relations_failed]}") # rubocop:disable Layout/LineLength
            counts
          end

          def gas_deposit_relations(relations:, source_ids:)
            counts = { relations: 0, relations_failed: 0, relations_skipped: 0 }
            return counts if relations.empty?
            unless !data_model_entry.nil? &&
                   !data_model_relation.nil?
              return counts.merge(relations_failed: relations.size)
            end

            entry_model = data_model_entry
            relation_model = data_model_relation
            seen = {}
            relations.each do |relation|
              type = relation[:relation_type].to_s
              weight = relation[:confidence]
              unless gas_relation_accepted?(type: type, confidence: weight)
                counts[:relations_skipped] += 1
                next
              end
              ids = source_ids[relation[:from_content]]
              source = entry_model[ids.first] if ids&.one?
              target = entry_model[relation[:to_id]] if relation[:to_id]
              unless source && target
                counts[:relations_failed] += 1
                next
              end

              key = [source.id, target.id, type]
              if source.id == target.id || source[:access_scope] != target[:access_scope] || seen[key]
                counts[:relations_skipped] += 1
                next
              end
              seen[key] = true
              relation_model.create(from_entry_id: source.id, to_entry_id: target.id, relation_type: type,
                                    weight: weight, source_agent: 'gas_pipeline')
              counts[:relations] += 1
            rescue StandardError => e
              counts[:relations_failed] += 1
              handle_exception(e, level: :warn, operation: 'apollo.gas.phase_deposit_relation')
            end
            counts
          end

          def gas_relation_accepted?(type:, confidence:)
            Legion::Extensions::Apollo::Helpers::Confidence::RELATION_TYPES.include?(type) &&
              confidence.is_a?(Numeric) && confidence.real? && confidence.finite? &&
              confidence.between?(settings[:gas][:relate_confidence_gate], 1.0)
          end

          # Phase 6: Anticipate - pre-cache likely follow-up questions
          def gas_phase_anticipate(facts, _synthesis)
            if facts.empty?
              log.debug('GAS phase_anticipate skipped reason=no_facts')
              return []
            end
            unless Legion::LLM.started?
              log.debug('GAS phase_anticipate skipped reason=llm_unavailable')
              return []
            end

            anticipations = gas_llm_anticipate(facts)
            log.debug("GAS phase_anticipate anticipations=#{anticipations.size}")
            anticipations
          end

          def gas_fetch_similar_entries(facts:, **)
            lim = settings[:gas][:similar_entries_limit]
            min_conf = settings[:query][:default_min_confidence]
            entries = []
            facts.each do |fact|
              result = Legion::Extensions::Apollo::Runners::Knowledge.retrieve_relevant(
                query: fact[:content], limit: lim, min_confidence: min_conf
              )
              raise IOError, "Apollo semantic retrieval failed: #{result[:error]}" unless result[:success]

              entries.concat(result[:entries])
            end
            unique = entries.uniq { |e| e[:id] }
            log.debug("GAS fetch_similar_entries facts=#{facts.size} entries=#{unique.size}")
            unique
          end

          def gas_classify_relation(fact, entry)
            fb_conf = settings[:gas][:fallback_confidence]
            if Legion::LLM.started?
              gas_llm_classify_relation(fact, entry)
            else
              { from_content: fact[:content], to_id: entry[:id], relation_type: 'similar_to', confidence: fb_conf }
            end
          end

          def gas_llm_classify_relation(fact, entry) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
            prompt = <<~PROMPT
              Classify the relationship between these two knowledge entries.
              Valid types: #{RELATION_TYPES.join(', ')}

              Entry A (new): #{fact[:content]}
              Entry B (existing): #{entry[:content]}

              Return JSON with relation_type and confidence (0.0-1.0).
            PROMPT

            result = Legion::LLM::Inference::GaiaCaller.structured(
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

            rels = if result.is_a?(Hash) && result[:data].is_a?(Hash)
                     result[:data][:relations] || result.dig(:data, 'relations') || []
                   else
                     content = result.respond_to?(:message) ? result.message[:content] : result.to_s
                     parsed = json_parse(content)
                     parsed.is_a?(Hash) ? (parsed[:relations] || parsed['relations'] || []) : []
                   end
            best = rels.max_by { |r| r[:confidence] || r['confidence'] || 0 }

            return gas_fallback_relation(fact, entry) unless best

            conf = best[:confidence] || best['confidence'] || 0
            rtype = best[:relation_type] || best['relation_type']
            return gas_fallback_relation(fact, entry) if conf < settings[:gas][:relate_confidence_gate] || !RELATION_TYPES.include?(rtype)

            { from_content: fact[:content], to_id: entry[:id], relation_type: rtype, confidence: conf }
          end

          def gas_fallback_relation(fact, entry)
            { from_content: fact[:content], to_id: entry[:id], relation_type: 'similar_to', confidence: settings[:gas][:fallback_confidence] }
          end

          def gas_llm_synthesize(facts)
            facts_text = facts.each_with_index.map { |f, i| "[#{i}] (#{f[:content_type]}) #{f[:content]}" }.join("\n")

            prompt = <<~PROMPT
              Given these knowledge entries, generate derivative insights (inferences, implications, or connections).
              Each synthesis should combine information from multiple sources.

              Entries:
              #{facts_text}

              Return JSON with a "synthesis" array where each item has: content (string), content_type (inference/implication/connection), source_indices (array of entry indices used).
            PROMPT

            result = Legion::LLM::Inference::GaiaCaller.structured(
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

            items = if result.is_a?(Hash) && result[:data].is_a?(Hash)
                      result[:data][:synthesis] || result.dig(:data, 'synthesis') || []
                    else
                      content = result.respond_to?(:message) ? result.message[:content] : result.to_s
                      parsed = json_parse(content)
                      parsed.is_a?(Hash) ? (parsed[:synthesis] || parsed['synthesis'] || []) : []
                    end

            items.map { |item| gas_build_synthesis_entry(item, facts) }
          end

          def gas_build_synthesis_entry(item, facts)
            source_indices = item[:source_indices] || item['source_indices'] || []
            source_confs = source_indices.filter_map { |i| facts[i]&.dig(:confidence) }
            fb = settings[:gas][:fallback_confidence]
            geo_mean = source_confs.empty? ? fb : gas_geometric_mean(source_confs)

            {
              content:        item[:content] || item['content'],
              content_type:   (item[:content_type] || item['content_type'] || 'inference').to_sym,
              status:         :candidate,
              confidence:     [geo_mean, settings[:gas][:synthesis_confidence_cap]].min,
              source_indices: source_indices
            }
          end

          def gas_geometric_mean(values)
            return 0.0 if values.empty?

            product = values.reduce(1.0) { |acc, v| acc * v }
            product**(1.0 / values.length)
          end

          def gas_llm_anticipate(facts)
            facts_text = facts.map { |f| "(#{f[:content_type]}) #{f[:content]}" }.join("\n")

            prompt = <<~PROMPT
              Given these knowledge entries, generate 1-3 likely follow-up questions a user might ask.

              Knowledge:
              #{facts_text}

              Return JSON with a "questions" array of question strings.
            PROMPT

            result = Legion::LLM::Inference::GaiaCaller.structured(
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

            questions = if result.is_a?(Hash) && result[:data].is_a?(Hash)
                          result[:data][:questions] || result.dig(:data, 'questions') || []
                        else
                          content = result.respond_to?(:message) ? result.message[:content] : result.to_s
                          parsed = json_parse(content)
                          parsed.is_a?(Hash) ? (parsed[:questions] || parsed['questions'] || []) : []
                        end
            questions = questions.first(settings[:gas][:max_anticipations])

            questions.map do |q|
              gas_promote_to_pattern_store(question: q, facts: facts)
              { question: q }
            end
          end

          def gas_promote_to_pattern_store(question:, facts:)
            return unless defined?(Legion::Extensions::Agentic::TBI::PatternStore)

            Legion::Extensions::Agentic::TBI::PatternStore.promote_candidate(
              intent:     question,
              resolution: { source: 'gas_anticipate', facts: facts.map { |f| f[:content] } },
              confidence: settings[:gas][:fallback_confidence]
            )
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'apollo.gas.promote_to_pattern_store')
            nil
          end

          def gas_mechanical_comprehend(_messages, response)
            [{ content: response, content_type: :observation }]
          end

          def gas_llm_comprehend(messages, response)
            prompt = <<~PROMPT
              Extract distinct facts from this exchange. Return JSON array of {content:, content_type:} where content_type is one of: fact, concept, procedure, association.

              User: #{messages.last&.dig(:content)}
              Assistant: #{response}
            PROMPT

            result = Legion::LLM::Inference::GaiaCaller.structured(
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

            facts_array = if result.is_a?(Hash) && result[:data].is_a?(Hash)
                            result[:data][:facts] || result.dig(:data, 'facts') || []
                          else
                            content = result.respond_to?(:message) ? result.message[:content] : result.to_s
                            parsed = json_parse(content)
                            parsed.is_a?(Hash) ? (parsed[:facts] || parsed['facts'] || []) : Array(parsed)
                          end
            facts_array.map do |f|
              {
                content:      f[:content] || f['content'],
                content_type: (f[:content_type] || f['content_type'] || 'fact').to_sym
              }
            end
          end
        end
      end
    end
  end
end
