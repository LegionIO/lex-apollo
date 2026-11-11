# frozen_string_literal: true

module Legion
  module Extensions
    module Apollo
      module Helpers
        module TagNormalizer
          ALIASES = {
            'c#' => 'csharp', '.net' => 'dotnet', 'c++' => 'cplusplus',
            'node.js' => 'nodejs', 'vue.js' => 'vuejs', 'react.js' => 'reactjs'
          }.freeze

          private

          def tag_normalize(raw:, **)
            tag = raw.to_s.strip.downcase
            tag = ALIASES[tag] if ALIASES.key?(tag)
            tag = tag.gsub(/[^a-z0-9\- ]/, '')
                     .gsub(/\s+/, '-').squeeze('-')
                     .sub(/^-/, '')
                     .sub(/-$/, '')
            tag.empty? ? nil : tag
          end

          def tag_normalize_all(tags:, max: 5, **)
            Array(tags)
              .filter_map { |tag| tag_normalize(raw: tag) }
              .uniq
              .first(max)
          end
        end
      end
    end
  end
end
