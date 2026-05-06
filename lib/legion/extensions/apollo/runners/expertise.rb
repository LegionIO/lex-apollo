# frozen_string_literal: true

require_relative '../helpers/data_models'

module Legion
  module Extensions
    module Apollo
      module Runners
        module Expertise
          def get_expertise(domain:, min_proficiency: Helpers::Confidence.apollo_setting(:expertise, :initial_proficiency, default: 0.0), **)
            { action: :expertise_query, domain: domain, min_proficiency: min_proficiency }
          end

          def domains_at_risk(min_agents: Helpers::Confidence.apollo_setting(:expertise, :min_agents_at_risk, default: 2), **)
            { action: :domains_at_risk, min_agents: min_agents }
          end

          def agent_profile(agent_id:, **)
            { action: :agent_profile, agent_id: agent_id }
          end

          def aggregate(**)
            unless Helpers::DataModels.apollo_entry_available?
              log.warn('Apollo Expertise.aggregate skipped: apollo_data_not_available')
              return { success: false, error: 'apollo_data_not_available' }
            end

            entries = Helpers::DataModels.apollo_entry
                                         .select(:source_agent, :tags, :confidence)
                                         .exclude(source_agent: nil)
                                         .all
            log.debug("Apollo Expertise.aggregate entries=#{entries.size}")

            agent_set = Set.new
            domain_set = Set.new

            expertise_groups(entries).each_value do |group|
              upsert_expertise_group(group)
              agent_set << group[:agent_id]
              domain_set << group[:domain]
            end

            { success: true, agents: agent_set.size, domains: domain_set.size }
              .tap { |result| log.info("Apollo Expertise.aggregate agents=#{result[:agents]} domains=#{result[:domains]}") }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.expertise.aggregate')
            { success: false, error: e.message }
          end

          def expertise_groups(entries)
            entries.each_with_object({}) do |entry, groups|
              agent = entry.source_agent
              domain = entry.tags.is_a?(Array) ? (entry.tags.first || 'general') : 'general'
              key = "#{agent}:#{domain}"
              groups[key] ||= { agent_id: agent, domain: domain, confidences: [] }
              groups[key][:confidences] << entry.confidence.to_f
            end
          end

          def upsert_expertise_group(group)
            count = group[:confidences].size
            proficiency = expertise_proficiency(group[:confidences])
            existing = Helpers::DataModels.apollo_expertise
                                          .where(agent_id: group[:agent_id], domain: group[:domain]).first

            if existing
              existing.update(proficiency: proficiency, entry_count: count, last_active_at: Time.now)
            else
              Helpers::DataModels.apollo_expertise.create(
                agent_id: group[:agent_id], domain: group[:domain],
                proficiency: proficiency, entry_count: count, last_active_at: Time.now
              )
            end
          end

          def expertise_proficiency(confidences)
            avg = confidences.sum / confidences.size
            cap = Helpers::Confidence.apollo_setting(:expertise, :proficiency_cap, default: 1.0)
            [avg * Math.log2(confidences.size + 1), cap].min
          end

          include Legion::Extensions::Helpers::Lex if defined?(Legion::Extensions::Helpers::Lex)
        end
      end
    end
  end
end
