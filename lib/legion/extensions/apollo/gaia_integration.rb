# frozen_string_literal: true

require_relative 'helpers/data_models'

module Legion
  module Extensions
    module Apollo
      module GaiaIntegration
        PUBLISH_CONFIDENCE_THRESHOLD = 0.6
        PUBLISH_NOVELTY_THRESHOLD = 0.3

        class << self
          def publish_insight(insight, agent_id:)
            return nil unless publishable?(insight)
            return nil unless defined?(Legion::Extensions::Apollo::Client)

            client = Legion::Extensions::Apollo::Client.new(agent_id: agent_id)
            client.store_knowledge(
              content:      insight[:content],
              content_type: :observation,
              source_agent: agent_id,
              tags:         Array(insight[:tags])
            )
          end

          def publishable?(insight)
            (insight[:confidence] || 0) > PUBLISH_CONFIDENCE_THRESHOLD &&
              (insight[:novelty] || 0) > PUBLISH_NOVELTY_THRESHOLD
          end

          def handle_mesh_departure(agent_id:)
            return nil unless Helpers::DataModels.apollo_expertise_available?

            sole_expert_domains = Helpers::DataModels.apollo_expertise
                                                     .where(agent_id: agent_id)
                                                     .all
                                                     .select { |e| sole_expert?(e.domain, agent_id) }
                                                     .map(&:domain)

            return nil if sole_expert_domains.empty?

            {
              event:           'knowledge_vulnerability',
              agent_id:        agent_id,
              domains_at_risk: sole_expert_domains,
              severity:        sole_expert_domains.size > 3 ? :critical : :warning
            }
          end

          private

          def sole_expert?(domain, agent_id)
            return false unless Helpers::DataModels.apollo_expertise_available?

            count = Helpers::DataModels.apollo_expertise
                                       .where(domain: domain)
                                       .exclude(agent_id: agent_id)
                                       .count
            count.zero?
          end
        end
      end
    end
  end
end
