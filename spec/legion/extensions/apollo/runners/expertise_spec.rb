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
end
