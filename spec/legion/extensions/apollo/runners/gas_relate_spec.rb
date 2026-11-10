# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/runners/gas'

RSpec.describe Legion::Extensions::Apollo::Runners::Gas, 'relation classification' do
  let(:facts) do
    [{ content: 'pgvector uses HNSW indexes', content_type: :fact },
     { content: 'cosine distance measures similarity', content_type: :concept }]
  end
  let(:similar_entries) do
    { success: true,
      entries: [{ id: 'e1', content: 'HNSW is an approximate nearest neighbor algorithm', content_type: 'concept', confidence: 0.85 }],
      count:   1 }
  end

  before do
    allow(Legion::LLM).to receive(:started?).and_return(false)
    allow(Legion::Extensions::Apollo::Runners::Knowledge).to receive(:retrieve_relevant).and_return(similar_entries)
  end

  it 'uses mechanical similar-to relations when the LLM is not started' do
    result = described_class.send(:gas_phase_relate, facts: facts)

    expect(result.map { |relation| [relation[:from_content], relation[:to_id], relation[:relation_type]] }).to eq(
      facts.map { |fact| [fact[:content], 'e1', 'similar_to'] }
    )
  end

  context 'with LLM classification available' do
    before { allow(Legion::LLM).to receive(:started?).and_return(true) }

    it 'uses a supported high-confidence classification' do
      allow(Legion::LLM::Inference::GaiaCaller).to receive(:structured)
        .and_return(data: { relations: [{ relation_type: 'depends_on', confidence: 0.85 }] })

      result = described_class.send(:gas_phase_relate, facts: facts)

      expect(result).to contain_exactly(
        include(from_content: facts[0][:content], to_id: 'e1', relation_type: 'depends_on', confidence: 0.85),
        include(from_content: facts[1][:content], to_id: 'e1', relation_type: 'depends_on', confidence: 0.85)
      )
    end

    it 'does not turn a weak contradiction classification into a contradiction edge' do
      allow(Legion::LLM::Inference::GaiaCaller).to receive(:structured)
        .and_return(data: { relations: [{ relation_type: 'contradicts', confidence: 0.3 }] })

      result = described_class.send(:gas_phase_relate, facts: facts)

      expect(result.map { |relation| relation[:relation_type] }).to eq(%w[similar_to similar_to])
    end
  end

  it 'returns no relations when retrieval succeeds without similar entries' do
    allow(Legion::Extensions::Apollo::Runners::Knowledge).to receive(:retrieve_relevant)
      .and_return(success: true, entries: [], count: 0)

    expect(described_class.send(:gas_phase_relate, facts: facts)).to eq([])
  end

  it 'propagates failed retrieval rather than treating it as an empty knowledge store' do
    allow(Legion::Extensions::Apollo::Runners::Knowledge).to receive(:retrieve_relevant)
      .and_return(success: false, error: 'database unavailable')

    expect { described_class.send(:gas_phase_relate, facts: facts) }
      .to raise_error(IOError, /database unavailable/)
  end
end
