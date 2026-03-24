# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/runners/gas'

RSpec.describe Legion::Extensions::Apollo::Runners::Gas, '.phase_synthesize' do
  let(:facts) do
    [
      { content: 'pgvector uses HNSW indexes', content_type: :fact, confidence: 0.9 },
      { content: 'HNSW provides logarithmic search time', content_type: :fact, confidence: 0.85 }
    ]
  end

  let(:relations) do
    [
      { from_content: 'pgvector uses HNSW indexes', to_id: 'e1', relation_type: 'depends_on', confidence: 0.8 }
    ]
  end

  context 'when GaiaCaller is unavailable' do
    it 'returns empty array' do
      result = described_class.phase_synthesize(facts, relations)
      expect(result).to eq([])
    end
  end

  context 'when GaiaCaller is available' do
    let(:gaia_caller) { double('GaiaCaller') }
    let(:mock_response) do
      double(
        'Response',
        message: {
          content: '{"synthesis":[{"content":"pgvector achieves fast search via HNSW",' \
                   '"content_type":"inference","source_indices":[0,1]}]}'
        }
      )
    end

    before do
      stub_const('Legion::LLM::Pipeline::GaiaCaller', gaia_caller)
      allow(gaia_caller).to receive(:structured).and_return(mock_response)
      allow(Legion::JSON).to receive(:load).and_return(
        {
          'synthesis' => [
            {
              'content'        => 'pgvector achieves fast similarity search through HNSW logarithmic indexing',
              'content_type'   => 'inference',
              'source_indices' => [0, 1]
            }
          ]
        }
      )
    end

    it 'generates derivative knowledge entries' do
      result = described_class.phase_synthesize(facts, relations)
      expect(result).not_to be_empty
      expect(result.first[:content]).to include('pgvector')
    end

    it 'marks entries as candidate status' do
      result = described_class.phase_synthesize(facts, relations)
      expect(result.first[:status]).to eq(:candidate)
    end

    it 'caps confidence at 0.7' do
      result = described_class.phase_synthesize(facts, relations)
      result.each do |entry|
        expect(entry[:confidence]).to be <= 0.7
      end
    end

    it 'includes depends_on source indices' do
      result = described_class.phase_synthesize(facts, relations)
      expect(result.first[:source_indices]).to eq([0, 1])
    end
  end

  context 'when LLM call fails' do
    let(:gaia_caller) { double('GaiaCaller') }

    before do
      stub_const('Legion::LLM::Pipeline::GaiaCaller', gaia_caller)
      allow(gaia_caller).to receive(:structured).and_raise(StandardError, 'LLM timeout')
    end

    it 'returns empty array on error' do
      result = described_class.phase_synthesize(facts, relations)
      expect(result).to eq([])
    end
  end

  context 'with empty inputs' do
    it 'returns empty array when no facts' do
      result = described_class.phase_synthesize([], [])
      expect(result).to eq([])
    end

    it 'returns empty array when single fact (nothing to synthesize)' do
      result = described_class.phase_synthesize(
        [{ content: 'one fact', content_type: :fact, confidence: 0.9 }],
        []
      )
      expect(result).to eq([])
    end
  end
end
