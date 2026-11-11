# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/settings/helper'
require 'legion/extensions/apollo/helpers/data_models'
require 'legion/extensions/apollo/helpers/storage'

module Legion
  module Extensions
    module Apollo
      module Runners
        module Expertise
          include Legion::Logging::Helper
          include Legion::Settings::Helper
          extend Legion::Extensions::Apollo::Helpers::DataModels
          extend Legion::Extensions::Apollo::Helpers::Storage
          extend self

          def get_expertise(domain:, min_proficiency: settings[:expertise][:initial_proficiency], **)
            model = data_model_expertise
            return { success: false, error: 'apollo_data_not_available' } unless model

            entries = model.where(domain: domain).where { proficiency >= min_proficiency }.order(Sequel.desc(:proficiency)).all
            formatted = entries.map(&:values)
            { success: true, domain: domain, min_proficiency: min_proficiency, entries: formatted, count: formatted.size }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.expertise.get_expertise', domain: domain)
            { success: false, error: e.message, entries: [], count: 0 }
          end

          def domains_at_risk(min_agents: settings[:expertise][:min_agents_at_risk], **)
            model = data_model_expertise
            return { success: false, error: 'apollo_data_not_available' } unless model

            agent_count = Sequel.function(:count, :agent_id).distinct
            domains = model.select_group(:domain).select_append(agent_count.as(:agent_count))
                           .having(agent_count < min_agents).order(:domain).naked.all
            { success: true, min_agents: min_agents, domains: domains, count: domains.size }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.expertise.domains_at_risk')
            { success: false, error: e.message, domains: [], count: 0 }
          end

          def agent_profile(agent_id:, **)
            model = data_model_expertise
            return { success: false, error: 'apollo_data_not_available' } unless model

            entries = model.where(agent_id: agent_id).order(:domain).all.map(&:values)
            { success: true, agent_id: agent_id, entries: entries, count: entries.size }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.expertise.agent_profile', agent_id: agent_id)
            { success: false, error: e.message, agent_id: agent_id, entries: [], count: 0 }
          end

          def aggregate(**)
            model = data_model_entry
            expertise_model = data_model_expertise
            unless model && expertise_model
              log.warn('Apollo Expertise.aggregate skipped: apollo_data_not_available')
              return { success: false, error: 'apollo_data_not_available' }
            end

            entries = model.select(:source_agent, :knowledge_domain, :tags, :confidence).exclude(source_agent: nil).all
            log.debug("Apollo Expertise.aggregate entries=#{entries.size}")

            agent_set = Set.new
            domain_set = Set.new
            expertise_groups(entries: entries).each_value do |group|
              expertise_upsert_group(model: expertise_model, group: group)
              agent_set << group[:agent_id]
              domain_set << group[:domain]
            end

            { success: true, agents: agent_set.size, domains: domain_set.size }
              .tap { |result| log.info("Apollo Expertise.aggregate agents=#{result[:agents]} domains=#{result[:domains]}") }
          rescue Sequel::Error => e
            handle_exception(e, level: :error, operation: 'apollo.expertise.aggregate')
            { success: false, error: e.message }
          end

          private

          def expertise_groups(entries:, **)
            entries.each_with_object({}) do |entry, groups|
              agent = entry.source_agent
              domain = entry.knowledge_domain ||
                       storage_deserialize_tags(tags: entry.tags).first || 'general'
              key = [agent, domain]
              groups[key] ||= { agent_id: agent, domain: domain, confidences: [] }
              groups[key][:confidences] << entry.confidence.to_f
            end
          end

          def expertise_upsert_group(model:, group:, **)
            count = group[:confidences].size
            proficiency = expertise_proficiency(confidences: group[:confidences])
            existing = model.first(agent_id: group[:agent_id], domain: group[:domain])

            if existing
              existing.update(proficiency: proficiency, entry_count: count, last_active_at: Time.now)
            else
              model.create(agent_id: group[:agent_id], domain: group[:domain], proficiency: proficiency,
                           entry_count: count, last_active_at: Time.now)
            end
          end

          def expertise_proficiency(confidences:, **)
            avg = confidences.sum / confidences.size
            cap = settings[:expertise][:proficiency_cap]
            [avg * Math.log2(confidences.size + 1), cap].min
          end
        end
      end
    end
  end
end
