# frozen_string_literal: true

require 'legion/settings/helper'

module Legion
  module Extensions
    module Apollo
      module Helpers
        module Confidence
          include Legion::Settings::Helper

          CONTENT_TYPES = %i[fact concept procedure association observation].freeze
          RELATION_TYPES = %w[is_a has_a part_of causes similar_to contradicts supersedes depends_on supports_by extends].freeze

          private

          def confidence_apply_retrieval_boost(confidence:, **)
            [confidence + settings[:confidence][:retrieval_boost], 1.0].min
          end

          def confidence_apply_corroboration_boost(confidence:, weight: 1.0, **)
            [confidence + (settings[:confidence][:corroboration_boost] * weight), 1.0].min
          end
        end
      end
    end
  end
end
