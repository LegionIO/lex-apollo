# frozen_string_literal: true

module Legion
  module Extensions
    module Apollo
      module Helpers
        module DataModels
          class << self
            def apollo_entry
              namespaced_apollo_model(:Entry) || legacy_model(:ApolloEntry)
            end

            def apollo_relation
              namespaced_apollo_model(:Relation) || legacy_model(:ApolloRelation)
            end

            def apollo_access_log
              namespaced_apollo_model(:AccessLog) || legacy_model(:ApolloAccessLog)
            end

            def apollo_expertise
              namespaced_apollo_model(:Expertise) || legacy_model(:ApolloExpertise)
            end

            def apollo_entry_available?
              !apollo_entry.nil?
            end

            def apollo_relation_available?
              !apollo_relation.nil?
            end

            def apollo_access_log_available?
              !apollo_access_log.nil?
            end

            def apollo_expertise_available?
              !apollo_expertise.nil?
            end

            private

            def namespaced_apollo_model(name)
              return nil unless defined?(Legion::Data::Model::Apollo)
              return nil unless Legion::Data::Model::Apollo.const_defined?(name, false)

              Legion::Data::Model::Apollo.const_get(name, false)
            end

            def legacy_model(name)
              return nil unless defined?(Legion::Data::Model)
              return nil unless Legion::Data::Model.const_defined?(name, false)

              Legion::Data::Model.const_get(name, false)
            end
          end
        end
      end
    end
  end
end
