# frozen_string_literal: true

require_relative 'helpers/confidence'
require_relative 'helpers/similarity'
require_relative 'helpers/graph_query'
require_relative 'runners/knowledge'
require_relative 'runners/expertise'
require_relative 'runners/maintenance'

module Legion
  module Extensions
    module Apollo
      class Client
        include Runners::Knowledge
        include Runners::Expertise
        include Runners::Maintenance

        attr_reader :agent_id

        def initialize(agent_id: 'unknown', **)
          @agent_id = agent_id
        end

        def store_knowledge(source_agent: nil, **)
          super(**, source_agent: source_agent || @agent_id)
        end
      end
    end
  end
end
