# frozen_string_literal: true

module Legion
  module Extensions
    module Apollo
      module Helpers
        module EntityWatchdog
          ENTITY_PATTERNS = {
            person:  /\b[A-Z][a-z]+(?:\s[A-Z][a-z]+)+\b/,
            service: %r{\bhttps?://[^\s]+\b},
            repo:    %r{\b[a-zA-Z0-9_-]+/[a-zA-Z0-9_.-]+\b}
          }.freeze

          class << self
            def detect_entities(text:, types: nil)
              return [] if text.nil? || text.empty?

              types = (types || default_types).map(&:to_sym)
              entities = []

              types.each do |type_sym|
                pattern = type_sym == :concept ? concept_pattern : ENTITY_PATTERNS[type_sym]
                next unless pattern

                text.scan(pattern).each do |match|
                  entities << { type: type_sym, value: match.strip, confidence: 0.5 }
                end
              end

              entities.uniq { |e| [e[:type], e[:value].downcase] }
            end

            def link_or_create(entities:, source_context: nil)
              return { success: true, linked: 0, created: 0 } if entities.nil? || entities.empty?

              linked = 0
              created = 0

              entities.each do |entity|
                existing = find_existing(entity)
                if existing
                  bump_confidence(existing, source_context)
                  linked += 1
                else
                  create_candidate(entity, source_context)
                  created += 1
                end
              end

              { success: true, linked: linked, created: created }
            end

            def concept_pattern
              keywords = if defined?(Legion::Settings)
                           Legion::Settings.dig(:apollo, :entity_watchdog, :concept_keywords) || []
                         else
                           []
                         end
              return nil if keywords.empty?

              Regexp.new("\\b(?:#{keywords.map { |k| Regexp.escape(k) }.join('|')})\\b", Regexp::IGNORECASE)
            end

            private

            def default_types
              if defined?(Legion::Settings)
                Legion::Settings.dig(:apollo, :entity_watchdog, :types) || %w[person service repo concept]
              else
                %w[person service repo concept]
              end
            end

            def find_existing(_entity)
              return nil unless defined?(Runners::Knowledge) && respond_to?(:retrieve_relevant, true)

              nil
            end

            def bump_confidence(_entry, _source_context)
              # Increment retrieval confidence on existing Apollo entry
            end

            def create_candidate(entity, _source_context)
              return unless defined?(Runners::Knowledge)

              Legion::Logging.debug "[entity_watchdog] candidate: #{entity[:type]}=#{entity[:value]}" if defined?(Legion::Logging)
            end
          end
        end
      end
    end
  end
end
