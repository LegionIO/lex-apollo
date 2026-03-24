# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/runners/gas'

RSpec.describe Legion::Extensions::Apollo::Runners::Gas, '.phase_anticipate' do
  let(:facts) do
    [
      { content: 'pgvector uses HNSW indexes', content_type: :fact },
      { content: 'cosine distance measures similarity', content_type: :concept }
    ]
  end

  let(:synthesis) do
    [
      { content: 'pgvector achieves fast search via HNSW', content_type: :inference, status: :candidate }
    ]
  end

  context 'when GaiaCaller is unavailable' do
    it 'returns empty array' do
      result = described_class.phase_anticipate(facts, synthesis)
      expect(result).to eq([])
    end
  end

  context 'when GaiaCaller is available' do
    let(:gaia_caller) { double('GaiaCaller') }
    let(:mock_response) do
      double(
        'Response',
        message: {
          content: '{"questions":["How fast is pgvector HNSW search?","What distance metrics does pgvector support?"]}'
        }
      )
    end

    before do
      stub_const('Legion::LLM::Pipeline::GaiaCaller', gaia_caller)
      allow(gaia_caller).to receive(:structured).and_return(mock_response)
      allow(Legion::JSON).to receive(:load).and_return(
        { 'questions' => ['How fast is pgvector HNSW search?', 'What distance metrics does pgvector support?'] }
      )
    end

    it 'generates anticipated questions' do
      result = described_class.phase_anticipate(facts, synthesis)
      expect(result).not_to be_empty
      expect(result.length).to be <= 3
    end

    it 'returns question strings' do
      result = described_class.phase_anticipate(facts, synthesis)
      result.each do |item|
        expect(item[:question]).to be_a(String)
      end
    end

    context 'when PatternStore is available' do
      let(:pattern_store) { double('PatternStore') }

      before do
        stub_const('Legion::Extensions::Agentic::TBI::PatternStore', pattern_store)
        allow(pattern_store).to receive(:promote_candidate)
      end

      it 'promotes candidates to PatternStore' do
        described_class.phase_anticipate(facts, synthesis)
        expect(pattern_store).to have_received(:promote_candidate).at_least(:once)
      end
    end

    context 'when PatternStore is not available' do
      it 'still returns questions without error' do
        result = described_class.phase_anticipate(facts, synthesis)
        expect(result).not_to be_empty
      end
    end
  end

  context 'when LLM call fails' do
    let(:gaia_caller) { double('GaiaCaller') }

    before do
      stub_const('Legion::LLM::Pipeline::GaiaCaller', gaia_caller)
      allow(gaia_caller).to receive(:structured).and_raise(StandardError, 'timeout')
    end

    it 'returns empty array on error' do
      result = described_class.phase_anticipate(facts, synthesis)
      expect(result).to eq([])
    end
  end

  context 'with empty facts' do
    it 'returns empty array' do
      result = described_class.phase_anticipate([], [])
      expect(result).to eq([])
    end
  end
end
