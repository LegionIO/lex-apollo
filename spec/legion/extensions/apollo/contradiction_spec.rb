# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Apollo Contradiction Detection' do
  let(:knowledge) { Object.new.extend(Legion::Extensions::Apollo::Runners::Knowledge) }

  describe '#llm_detects_conflict?' do
    it 'returns false when LLM unavailable' do
      expect(knowledge.send(:llm_detects_conflict?, 'sky is blue', 'sky is red')).to be false
    end
  end

  describe '#detect_contradictions' do
    it 'returns empty when ApolloEntry model unavailable' do
      expect(knowledge.send(:detect_contradictions, 1, nil, 'test')).to eq([])
    end

    it 'returns empty when embedding is nil' do
      expect(knowledge.send(:detect_contradictions, 'uuid-1', nil, 'test')).to eq([])
    end

    context 'when entries exist' do
      let(:mock_entry_class) { double('ApolloEntry') }
      let(:mock_relation_class) { double('ApolloRelation') }
      let(:mock_db) { double('db') }
      let(:embedding) { Array.new(1536, 0.1) }

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
        stub_const('Legion::Data::Model::ApolloRelation', mock_relation_class)
        allow(mock_entry_class).to receive(:db).and_return(mock_db)
      end

      it 'queries with ORDER BY embedding distance' do
        allow(mock_db).to receive(:fetch).and_return(double(all: []))
        knowledge.send(:detect_contradictions, 'uuid-1', embedding, 'test')
        expect(mock_db).to have_received(:fetch).with(
          a_string_including('ORDER BY embedding <=> :embedding'),
          hash_including(:entry_id, :embedding)
        )
      end

      it 'returns empty when no similar entries found' do
        allow(mock_db).to receive(:fetch).and_return(double(all: []))
        result = knowledge.send(:detect_contradictions, 'uuid-1', embedding, 'test')
        expect(result).to eq([])
      end
    end
  end
end
