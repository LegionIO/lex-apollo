# frozen_string_literal: true

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
            return { success: false, error: 'apollo_data_not_available' } unless defined?(Legion::Data::Model::ApolloEntry)

            entries = Legion::Data::Model::ApolloEntry
                      .select(:source_agent, :tags, :confidence)
                      .exclude(source_agent: nil)
                      .all

            groups = {}
            entries.each do |entry|
              agent = entry.source_agent
              domain = entry.tags.is_a?(Array) ? (entry.tags.first || 'general') : 'general'
              key = "#{agent}:#{domain}"
              groups[key] ||= { agent_id: agent, domain: domain, confidences: [] }
              groups[key][:confidences] << entry.confidence.to_f
            end

            agent_set = Set.new
            domain_set = Set.new

            groups.each_value do |group|
              avg = group[:confidences].sum / group[:confidences].size
              count = group[:confidences].size
              cap = Helpers::Confidence.apollo_setting(:expertise, :proficiency_cap, default: 1.0)
              proficiency = [avg * Math.log2(count + 1), cap].min

              existing = Legion::Data::Model::ApolloExpertise
                         .where(agent_id: group[:agent_id], domain: group[:domain]).first

              if existing
                existing.update(proficiency: proficiency, entry_count: count, last_active_at: Time.now)
              else
                Legion::Data::Model::ApolloExpertise.create(
                  agent_id: group[:agent_id], domain: group[:domain],
                  proficiency: proficiency, entry_count: count, last_active_at: Time.now
                )
              end

              agent_set << group[:agent_id]
              domain_set << group[:domain]
            end

            { success: true, agents: agent_set.size, domains: domain_set.size }
          rescue Sequel::Error => e
            { success: false, error: e.message }
          end

          include Legion::Extensions::Helpers::Lex if defined?(Legion::Extensions::Helpers::Lex)
        end
      end
    end
  end
end
