# frozen_string_literal: true

require 'legion/data'
require 'legion/llm'
require 'legion/settings/helper'

module Legion
  module Extensions
    module Apollo
      module Helpers
        module Capability
          include Legion::Settings::Helper

          private

          def capability_can_embed?
            Legion::LLM.started? && Legion::LLM.can_embed?
          end

          def capability_can_write?
            settings[:data][:apollo_write] == true && Legion::Data.can_write?(:apollo_entries)
          end
        end
      end
    end
  end
end
