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
            include Legion::Logging::Helper
            include Legion::Settings::Helper

            def detect_entities(text:, types: nil)
              return [] if text.nil? || text.empty?

              types = (types || default_types).map(&:to_sym)
              entities = []

              types.each do |type_sym|
                entity_type = type_sym == :repository ? :repo : type_sym
                pattern = entity_type == :concept ? concept_pattern : ENTITY_PATTERNS[entity_type]
                next unless pattern

                text.scan(pattern).each do |match|
                  entities << { type: entity_type, value: match.strip,
confidence: Confidence.apollo_setting(:entity_watchdog, :detect_confidence, default: 0.5) }
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
              keywords = settings[:entity_watchdog][:concept_keywords]
              return nil if keywords.empty?

              Regexp.new("\\b(?:#{keywords.map { |k| Regexp.escape(k) }.join('|')})\\b", Regexp::IGNORECASE)
            end

            private

            def default_types
              settings[:entity_watchdog][:types]
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

              log.debug "[entity_watchdog] candidate: #{entity[:type]}=#{entity[:value]}"
            end
          end
        end
      end
    end
  end
end
