# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Apollo Contradiction Detection' do
  let(:knowledge) { Object.new.extend(Legion::Extensions::Apollo::Runners::Knowledge) }

  it 'does not assert a contradiction when the LLM is unavailable' do
    hide_const('Legion::LLM')
    expect(knowledge.send(:llm_detects_conflict?, content_a: 'sky is blue', content_b: 'sky is red')).to be false
  end

  it 'bounds both statements before sending them to the conflict model' do
    llm = Module.new
    stub_const('Legion::LLM', llm)
    received = nil
    allow(llm).to receive(:structured) do |messages:, **|
      received = messages.last[:content]
      { data: { contradicts: false } }
    end

    expect(knowledge.send(:llm_detects_conflict?, content_a: 'a' * 10_000, content_b: 'b' * 10_000)).to be false
    expect(received).to eq("A: #{'a' * 4000}\n\nB: #{'b' * 4000}")
  end

  context 'with persisted embeddings' do
    let(:db) { Sequel.sqlite }

    before do
      db.create_table(:apollo_entries) do
        primary_key :id
        String :content
        String :content_type, default: 'fact'
        Float :confidence, default: 0.8
        String :tags, default: '[]'
        String :source_agent, default: 'test'
        Integer :access_count, default: 0
        DateTime :created_at
        String :knowledge_domain, default: 'general'
        String :access_scope, default: 'private'
        Integer :identity_principal_id
        String :status, default: 'confirmed'
        String :embedding
        String :embedding_space_id
        Integer :embedding_dimensions
        String :embedding_provenance
      end
      db.create_table(:apollo_relations) do
        primary_key :id
        Integer :from_entry_id
        Integer :to_entry_id
        String :relation_type
        String :source_agent
        Float :weight
      end
      stub_const('Legion::Data::Model::Apollo::Entry', Class.new(Sequel::Model(db[:apollo_entries])))
      stub_const('Legion::Data::Model::Apollo::Relation', Class.new(Sequel::Model(db[:apollo_relations])))
      llm = Module.new do
        def self.structured(**)
          { data: { contradicts: true } }
        end
      end
      stub_const('Legion::LLM', llm)
    end

    after { db.disconnect }

    def insert_entry(content:, owner: 41, model: 'test', provenance: nil, **)
      result = ApolloSpecEmbedding.result(model: model)
      provenance ||= result[:embedding_provenance]
      db[:apollo_entries].insert(
        content: content, identity_principal_id: owner, embedding: Legion::JSON.dump(result[:vector]),
        embedding_space_id: provenance[:space_id], embedding_dimensions: provenance[:dimensions],
        embedding_provenance: Legion::JSON.dump(provenance)
      )
    end

    it 'disputes only compatible same-owner records using the current persisted vector' do
      source = insert_entry(content: 'Source statement')
      match = insert_entry(content: 'Conflicting statement')
      other_owner = insert_entry(content: 'Other owner statement', owner: 42)
      other_model = insert_entry(content: 'Other model statement', model: 'other')
      stale_provenance = ApolloSpecEmbedding.result[:embedding_provenance].merge(model: 'changed-without-space-update')
      inconsistent = insert_entry(content: 'Inconsistent provenance', provenance: stale_provenance)
      legacy = db[:apollo_entries].insert(content: 'Legacy statement', identity_principal_id: 41, embedding: '[1.0,0.0]')

      expect(knowledge.send(:detect_contradictions, entry_id: source)).to eq([match])
      expect(db[:apollo_entries].where(status: 'disputed').select_map(:id)).to contain_exactly(source, match)
      expect(db[:apollo_entries].where(id: [other_owner, other_model, inconsistent, legacy]).select_map(:status)).to all(eq('confirmed'))
      expect(db[:apollo_relations].select(:from_entry_id, :to_entry_id, :relation_type).all).to eq(
        [{ from_entry_id: source, to_entry_id: match, relation_type: 'contradicts' }]
      )
    end

    it 'leaves legacy rows without provenance undisputed instead of guessing their embedding model' do
      source = db[:apollo_entries].insert(content: 'Unknown model', identity_principal_id: 41, embedding: '[1.0,0.0]')
      insert_entry(content: 'Known model')

      expect(knowledge.send(:detect_contradictions, entry_id: source)).to eq([])
      expect(db[:apollo_entries].where(status: 'disputed').count).to eq(0)
    end
  end
end
