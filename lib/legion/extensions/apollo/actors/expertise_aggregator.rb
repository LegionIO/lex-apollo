# frozen_string_literal: true

require 'legion/extensions/actors/every'
require_relative '../runners/expertise'

module Legion
  module Extensions
    module Apollo
      module Actor
        class ExpertiseAggregator < Legion::Extensions::Actors::Every
          def runner_class    = Legion::Extensions::Apollo::Runners::Expertise
          def runner_function = 'aggregate'
          def time            = (defined?(Legion::Settings) && Legion::Settings.dig(:apollo, :actors, :expertise_interval)) || 1800
          def run_now?        = false
          def use_runner?     = false
          def check_subtask?  = false
          def generate_task?  = false
        end
      end
    end
  end
end
