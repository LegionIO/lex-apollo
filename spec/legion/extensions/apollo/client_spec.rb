# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/client'

RSpec.describe Legion::Extensions::Apollo::Client do
  let(:client) { described_class.new(agent_id: 'test-agent') }

  describe '#initialize' do
    it 'stores agent_id' do
      expect(client.agent_id).to eq('test-agent')
    end

    it 'defaults agent_id to unknown' do
      c = described_class.new
      expect(c.agent_id).to eq('unknown')
    end
  end

  describe 'Knowledge runner' do
    it 'responds to store_knowledge' do
      expect(client).to respond_to(:store_knowledge)
    end

    it 'injects source_agent from client agent_id' do
      result = client.store_knowledge(content: 'test fact', content_type: :fact)
      expect(result[:source_agent]).to eq('test-agent')
    end

    it 'allows source_agent override' do
      result = client.store_knowledge(content: 'test', content_type: :fact, source_agent: 'other')
      expect(result[:source_agent]).to eq('other')
    end

    it 'responds to query_knowledge' do
      expect(client).to respond_to(:query_knowledge)
    end

    it 'responds to related_entries' do
      expect(client).to respond_to(:related_entries)
    end

    it 'responds to deprecate_entry' do
      expect(client).to respond_to(:deprecate_entry)
    end
  end

  describe 'Expertise runner' do
    it 'responds to get_expertise' do
      expect(client).to respond_to(:get_expertise)
    end

    it 'responds to domains_at_risk' do
      expect(client).to respond_to(:domains_at_risk)
    end

    it 'responds to agent_profile' do
      expect(client).to respond_to(:agent_profile)
    end
  end

  describe 'Maintenance runner' do
    it 'responds to force_decay' do
      expect(client).to respond_to(:force_decay)
    end

    it 'responds to archive_stale' do
      expect(client).to respond_to(:archive_stale)
    end

    it 'responds to resolve_dispute' do
      expect(client).to respond_to(:resolve_dispute)
    end
  end
end
