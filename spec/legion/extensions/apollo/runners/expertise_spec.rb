# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/runners/expertise'

RSpec.describe Legion::Extensions::Apollo::Runners::Expertise do
  let(:runner) { described_class }
  let(:database) { Sequel.sqlite }
  let(:entry_model) { Class.new(Sequel::Model(database[:apollo_entries])) }
  let(:expertise_model) { Class.new(Sequel::Model(database[:apollo_expertise])) }

  before do
    allow(runner).to receive(:settings).and_return(Legion::Extensions::Apollo.settings)
    database.create_table(:apollo_entries) do
      primary_key :id
      String :source_agent
      String :knowledge_domain
      String :tags
      Float :confidence
    end
    database.create_table(:apollo_expertise) do
      primary_key :id
      String :agent_id
      String :domain
      Float :proficiency
      Integer :entry_count
      DateTime :last_active_at
    end
    stub_const('Legion::Data::Model::Apollo::Entry', entry_model)
    stub_const('Legion::Data::Model::Apollo::Expertise', expertise_model)
  end

  after { database.disconnect }

  describe '#get_expertise' do
    it 'returns persisted expertise ordered by proficiency' do
      expertise_model.create(agent_id: 'worker-1', domain: 'vault', proficiency: 0.8, entry_count: 2)
      expertise_model.create(agent_id: 'worker-2', domain: 'vault', proficiency: 0.6, entry_count: 1)

      result = runner.get_expertise(domain: 'vault', min_proficiency: 0.0)

      expect(result).to include(success: true, domain: 'vault', count: 2)
      expect(result[:entries].map { |entry| entry[:agent_id] }).to eq(%w[worker-1 worker-2])
    end
  end

  describe '#domains_at_risk' do
    it 'counts distinct agents per domain using SQL aggregation' do
      expertise_model.create(agent_id: 'worker-1', domain: 'vault', proficiency: 0.8, entry_count: 2)
      expertise_model.create(agent_id: 'worker-2', domain: 'vault', proficiency: 0.7, entry_count: 1)
      expertise_model.create(agent_id: 'worker-1', domain: 'claims', proficiency: 0.7, entry_count: 1)

      result = runner.domains_at_risk(min_agents: 3)

      expect(result).to include(success: true, min_agents: 3, count: 2)
      expect(result[:domains]).to contain_exactly(
        include(domain: 'claims', agent_count: 1), include(domain: 'vault', agent_count: 2)
      )
    end
  end

  describe '#agent_profile' do
    it 'returns one agent profile ordered by domain' do
      expertise_model.create(agent_id: 'worker-1', domain: 'vault', proficiency: 0.8, entry_count: 2)
      expertise_model.create(agent_id: 'worker-1', domain: 'claims', proficiency: 0.7, entry_count: 1)
      expertise_model.create(agent_id: 'worker-2', domain: 'vault', proficiency: 0.6, entry_count: 1)

      result = runner.agent_profile(agent_id: 'worker-1')

      expect(result).to include(success: true, agent_id: 'worker-1', count: 2)
      expect(result[:entries].map { |entry| entry[:domain] }).to eq(%w[claims vault])
    end
  end

  describe '#aggregate' do
    it 'returns an explicit error when canonical Apollo models are unavailable' do
      hide_const('Legion::Data::Model::Apollo')

      expect(runner.aggregate).to include(success: false, error: 'apollo_data_not_available')
    end

    it 'groups by agent and domain without collapsing domain collisions' do
      entry_model.create(source_agent: 'agent-1', knowledge_domain: 'ruby', confidence: 0.8)
      entry_model.create(source_agent: 'agent-1', knowledge_domain: 'ruby', confidence: 0.6)
      entry_model.create(source_agent: 'agent-1', knowledge_domain: 'python', confidence: 0.9)
      entry_model.create(source_agent: 'agent-2', knowledge_domain: 'ruby', confidence: 0.7)

      result = runner.aggregate

      expect(result).to include(success: true, agents: 2, domains: 2)
      rows = expertise_model.order(:agent_id, :domain).all.map { |row| [row.agent_id, row.domain, row.entry_count] }
      expect(rows).to eq([['agent-1', 'python', 1], ['agent-1', 'ruby', 2], ['agent-2', 'ruby', 1]])
      expect(expertise_model.where(agent_id: 'agent-1', domain: 'ruby').count).to eq(1)
    end

    it 'derives a missing domain from the first serialized tag' do
      entry_model.create(source_agent: 'agent-1', knowledge_domain: nil, tags: '["vault"]', confidence: 0.8)

      expect(runner.aggregate).to include(success: true, agents: 1, domains: 1)
      expect(expertise_model.first.values).to include(agent_id: 'agent-1', domain: 'vault', entry_count: 1)
    end

    it 'returns zero counts for an empty canonical entry table' do
      expect(runner.aggregate).to include(success: true, agents: 0, domains: 0)
    end
  end
end
