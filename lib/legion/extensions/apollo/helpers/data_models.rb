# frozen_string_literal: true

require 'legion/data'

module Legion
  module Extensions
    module Apollo
      module Helpers
        module DataModels
          private

          def data_model_entry
            return unless defined?(Legion::Data::Model::Apollo::Entry)

            Legion::Data::Model::Apollo::Entry
          end

          def data_model_relation
            return unless defined?(Legion::Data::Model::Apollo::Relation)

            Legion::Data::Model::Apollo::Relation
          end

          def data_model_access_log
            return unless defined?(Legion::Data::Model::Apollo::AccessLog)

            Legion::Data::Model::Apollo::AccessLog
          end

          def data_model_expertise
            return unless defined?(Legion::Data::Model::Apollo::Expertise)

            Legion::Data::Model::Apollo::Expertise
          end

          def data_model_task_log
            return unless defined?(Legion::Data::Model::TaskLog)

            Legion::Data::Model::TaskLog
          end
        end
      end
    end
  end
end
