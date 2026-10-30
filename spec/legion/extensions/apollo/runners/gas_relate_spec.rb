# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/runners/gas'

RSpec.describe Legion::Extensions::Apollo::Runners::Gas, '.phase_relate' do
  let(:facts) do
    [
      { content: 'pgvector uses HNSW indexes', content_type: :fact },
      { content: 'cosine distance measures similarity', content_type: :concept }
    ]
  end

  context 'when Apollo Knowledge is unavailable' do
    before do
      hide_const('Legion::Extensions::Apollo::Runners::Knowledge') if defined?(Legion::Extensions::Apollo::Runners::Knowledge)
    end

    it 'returns empty array' do
      result = described_class.phase_relate(facts: facts)
      expect(result).to eq([])
    end
  end

  context 'when Apollo has similar entries' do
    let(:knowledge_runner) { Module.new }
    let(:similar_entries) do
      {
        success: true,
        entries: [
          { id: 'e1', content: 'HNSW is an approximate nearest neighbor algorithm', content_type: 'concept', confidence: 0.85 }
        ],
        count:   1
      }
    end

    before do
      stub_const('Legion::Extensions::Apollo::Runners::Knowledge', knowledge_runner)
      response = similar_entries
      knowledge_runner.define_method(:retrieve_relevant) { |**| response }
    end

    context 'when GaiaCaller is unavailable' do
      it 'falls back to similar_to relations' do
        result = described_class.phase_relate(facts: facts)
        expect(result.map { |relation| [relation[:from_content], relation[:to_id], relation[:relation_type]] }).to eq(
          facts.map { |fact| [fact[:content], 'e1', 'similar_to'] }
        )
      end
    end

    context 'when GaiaCaller is available' do
      let(:gaia_caller) { double('GaiaCaller') }
      let(:mock_response) do
        double(
          'Response',
          message: {
            content: '{"relations":[{"relation_type":"depends_on","confidence":0.85}]}'
          }
        )
      end

      before do
        stub_const('Legion::LLM::Pipeline::GaiaCaller', gaia_caller)
        allow(gaia_caller).to receive(:structured).and_return(mock_response)
      end

      it 'classifies relations via LLM' do
        result = described_class.phase_relate(facts: facts)
        expect(result.first[:relation_type]).to eq('depends_on')
      end

      it 'gates on confidence > 0.7' do
        low_conf_response = double(
          'Response',
          message: {
            content: '{"relations":[{"relation_type":"contradicts","confidence":0.3}]}'
          }
        )
        allow(gaia_caller).to receive(:structured).and_return(low_conf_response)

        result = described_class.phase_relate(facts: facts)
        # Low confidence relations should fall back to similar_to
        classified = result.select { |r| r[:relation_type] == 'contradicts' }
        expect(result.map { |relation| relation[:relation_type] }).to eq(%w[similar_to similar_to])
        expect(classified).to be_empty
      end
    end
  end

  context 'when Apollo returns no similar entries' do
    let(:knowledge_runner) { Module.new }

    before do
      stub_const('Legion::Extensions::Apollo::Runners::Knowledge', knowledge_runner)
      knowledge_runner.define_method(:retrieve_relevant) { |**| { success: true, entries: [], count: 0 } }
    end

    it 'returns empty array' do
      result = described_class.phase_relate(facts: facts)
      expect(result).to eq([])
    end
  end
end
