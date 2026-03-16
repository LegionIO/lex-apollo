# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/runners/expertise'

RSpec.describe Legion::Extensions::Apollo::Runners::Expertise do
  let(:runner) do
    obj = Object.new
    obj.extend(described_class)
    obj
  end

  describe '#get_expertise' do
    it 'returns an expertise query payload' do
      result = runner.get_expertise(domain: 'vault')
      expect(result[:action]).to eq(:expertise_query)
      expect(result[:domain]).to eq('vault')
      expect(result[:min_proficiency]).to eq(0.0)
    end
  end

  describe '#domains_at_risk' do
    it 'returns an at-risk query payload' do
      result = runner.domains_at_risk(min_agents: 2)
      expect(result[:action]).to eq(:domains_at_risk)
      expect(result[:min_agents]).to eq(2)
    end
  end

  describe '#agent_profile' do
    it 'returns a profile query payload' do
      result = runner.agent_profile(agent_id: 'worker-1')
      expect(result[:action]).to eq(:agent_profile)
      expect(result[:agent_id]).to eq('worker-1')
    end
  end

  describe '#aggregate' do
    let(:host) { Object.new.extend(described_class) }

    context 'when Apollo data is not available' do
      before { hide_const('Legion::Data::Model::ApolloEntry') if defined?(Legion::Data::Model::ApolloEntry) }

      it 'returns a structured error' do
        result = host.aggregate
        expect(result[:success]).to be false
        expect(result[:error]).to eq('apollo_data_not_available')
      end
    end

    context 'when entries exist' do
      let(:mock_entry_class) { double('ApolloEntry') }
      let(:mock_expertise_class) { double('ApolloExpertise') }
      let(:entries) do
        [
          double('e1', source_agent: 'agent-1', tags: ['ruby'], confidence: 0.8),
          double('e2', source_agent: 'agent-1', tags: ['ruby'], confidence: 0.6),
          double('e3', source_agent: 'agent-2', tags: ['python'], confidence: 0.9)
        ]
      end

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
        stub_const('Legion::Data::Model::ApolloExpertise', mock_expertise_class)
        allow(mock_entry_class).to receive(:select).and_return(double(exclude: double(all: entries)))
        allow(mock_expertise_class).to receive(:where).and_return(double(first: nil))
        allow(mock_expertise_class).to receive(:create)
      end

      it 'returns agent and domain counts' do
        result = host.aggregate
        expect(result[:success]).to be true
        expect(result[:agents]).to eq(2)
        expect(result[:domains]).to eq(2)
      end

      it 'creates expertise records' do
        expect(mock_expertise_class).to receive(:create).twice
        host.aggregate
      end

      it 'computes proficiency using log2 formula' do
        # agent-1 ruby: avg=0.7, count=2, proficiency = 0.7 * log2(3) = 0.7 * 1.585 = 1.109 -> capped at 1.0
        expect(mock_expertise_class).to receive(:create).with(
          hash_including(agent_id: 'agent-1', domain: 'ruby', proficiency: 1.0)
        )
        # agent-2 python: avg=0.9, count=1, proficiency = 0.9 * log2(2) = 0.9 * 1.0 = 0.9
        expect(mock_expertise_class).to receive(:create).with(
          hash_including(agent_id: 'agent-2', domain: 'python', proficiency: 0.9)
        )
        host.aggregate
      end
    end

    context 'when no entries exist' do
      let(:mock_entry_class) { double('ApolloEntry') }

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
        allow(mock_entry_class).to receive(:select).and_return(double(exclude: double(all: [])))
      end

      it 'returns zero counts' do
        result = host.aggregate
        expect(result[:success]).to be true
        expect(result[:agents]).to eq(0)
        expect(result[:domains]).to eq(0)
      end
    end
  end
end
