# frozen_string_literal: true

module Legion
  module Extensions
    module Apollo
      module Runners
        module Maintenance
          def force_decay(factor: 0.5, **)
            { action: :force_decay, factor: factor }
          end

          def archive_stale(days: 90, **)
            { action: :archive_stale, days: days }
          end

          def resolve_dispute(entry_id:, resolution:, **)
            { action: :resolve_dispute, entry_id: entry_id, resolution: resolution }
          end

          include Legion::Extensions::Helpers::Lex if defined?(Legion::Extensions::Helpers::Lex)
        end
      end
    end
  end
end
