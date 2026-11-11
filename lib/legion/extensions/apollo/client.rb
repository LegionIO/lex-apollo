# frozen_string_literal: true

require 'legion/extensions/apollo/helpers/confidence'
require 'legion/extensions/apollo/helpers/similarity'
require 'legion/extensions/apollo/helpers/graph_query'
require 'legion/extensions/apollo/runners/knowledge'
require 'legion/extensions/apollo/runners/expertise'
require 'legion/extensions/apollo/runners/maintenance'

module Legion
  module Extensions
    module Apollo
      class Client
        include Legion::Extensions::Apollo::Helpers::DataModels
        include Legion::Extensions::Apollo::Helpers::Confidence
        include Legion::Extensions::Apollo::Helpers::TagNormalizer
        include Legion::Extensions::Apollo::Helpers::Storage
        include Legion::Extensions::Apollo::Helpers::Embedding
        include Legion::Extensions::Apollo::Helpers::Similarity
        include Legion::Extensions::Apollo::Helpers::GraphQuery
        include Legion::Extensions::Apollo::Runners::Knowledge
        include Legion::Extensions::Apollo::Runners::Expertise
        include Legion::Extensions::Apollo::Runners::Maintenance

        attr_reader :agent_id

        def initialize(agent_id: 'unknown', **)
          @agent_id = agent_id
        end

        def segments
          [:apollo]
        end

        def store_knowledge(source_agent: nil, **)
          super(**, source_agent: source_agent || @agent_id)
        end
      end
    end
  end
end
