# frozen_string_literal: true

module Legion
  module Extensions
    module Apollo
      module Runners
        module Expertise
          def get_expertise(domain:, min_proficiency: 0.0, **)
            { action: :expertise_query, domain: domain, min_proficiency: min_proficiency }
          end

          def domains_at_risk(min_agents: 2, **)
            { action: :domains_at_risk, min_agents: min_agents }
          end

          def agent_profile(agent_id:, **)
            { action: :agent_profile, agent_id: agent_id }
          end

          include Legion::Extensions::Helpers::Lex if defined?(Legion::Extensions::Helpers::Lex)
        end
      end
    end
  end
end
