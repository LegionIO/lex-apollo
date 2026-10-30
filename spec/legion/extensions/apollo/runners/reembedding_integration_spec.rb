# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'
require 'json'

RSpec.describe 'Apollo reembedding and space isolation' do
  let(:reembedding_script) do
    <<~'RUBY'
      require 'sequel'
      require 'rspec'
      require 'spec_helper'
      require 'json'
      db = Sequel.sqlite
      db.create_table(:apollo_entries) do
        primary_key :id
        String :content
        String :content_hash
        String :content_type
        String :status
        String :access_scope
        Integer :identity_principal_id
        Integer :identity_id
        String :identity_canonical_name
        Float :confidence
        String :tags
        String :source_agent
        String :source_context
        String :knowledge_domain
        Integer :access_count, default: 0
        String :embedding
        String :embedding_space_id
        Integer :embedding_dimensions
        String :embedding_provenance
        DateTime :created_at
        DateTime :updated_at
      end
      db.run <<~SQL
        CREATE UNIQUE INDEX idx_apollo_content_hash_owner ON apollo_entries (
          content_hash, access_scope,
          (CASE WHEN access_scope = 'global' THEN 0 ELSE COALESCE(identity_principal_id, 0) END)
        ) WHERE status != 'archived' AND content_hash IS NOT NULL
      SQL
      db.create_table(:apollo_access_log) do
        primary_key :id
        Integer :entry_id
        String :agent_id
        String :action
      end
      db.create_table(:identities) do
        Integer :id
        Integer :principal_id
      end
      db.create_table(:identity_group_memberships) do
        Integer :principal_id
        Integer :group_id
      end
      Legion::Data.const_set(:Model, Module.new) unless defined?(Legion::Data::Model)
      Legion::Data::Model.const_set(:Apollo, Module.new)
      { Entry: :apollo_entries, AccessLog: :apollo_access_log }.each do |name, table|
        Legion::Data::Model::Apollo.const_set(name, Class.new(Sequel::Model(db[table])))
      end
      input = ::JSON.parse($stdin.read, symbolize_names: true)
      input[:entries].each do |entry|
        profile = entry.delete(:embedding_profile)
        attributes = {
          content_type: 'fact', status: 'confirmed', access_scope: 'global', confidence: 0.8,
          tags: '[]', source_agent: 'migration-fixture', knowledge_domain: 'general',
          source_context: ::JSON.generate(origin: 'preserve'), created_at: Time.now,
          content_hash: Legion::Extensions::Apollo::Helpers::Writeback.content_hash(content: entry[:content])
        }.merge(entry)
        if profile
          embedding = ApolloSpecEmbedding.result(**profile)
          attributes.merge!(embedding: ::JSON.generate(embedding[:vector]), embedding_dimensions: embedding[:dimensions],
                            embedding_space_id: embedding[:embedding_provenance][:space_id],
                            embedding_provenance: ::JSON.generate(embedding[:embedding_provenance]))
        end
        db[:apollo_entries].insert(attributes)
      end
      Legion.const_set(:LLM, Module.new) unless defined?(Legion::LLM)
      Legion::LLM.const_set(:Call, Module.new) unless defined?(Legion::LLM::Call)
      Legion::LLM::Call.const_set(:Embeddings, Module.new) unless defined?(Legion::LLM::Call::Embeddings)
      selected_profile = input.fetch(:generated_profile, {})
      Legion::LLM::Call::Embeddings.define_singleton_method(:generate) do |text:, task:, **|
        raise 'provider call inside persistence transaction' if db.in_transaction?
        raise 'provider unavailable for document' if Array(input[:provider_failures]).include?(text)

        if task.to_s == 'document' && input[:concurrent_update]
          update = input.delete(:concurrent_update)
          db[:apollo_entries].where(id: update[:id]).update(
            content: update[:content],
            content_hash: Legion::Extensions::Apollo::Helpers::Writeback.content_hash(content: update[:content])
          )
        end
        ApolloSpecEmbedding.result(task: task, **selected_profile)
      end
      before = db[:apollo_entries].order(:id).all
      maintenance = Object.new.extend(Legion::Extensions::Apollo::Runners::Maintenance)
      results = input.fetch(:batches, []).map { |options| maintenance.reembed_entries(**options) }
      persisted = db[:apollo_entries].order(:id).all
      knowledge = Object.new.extend(Legion::Extensions::Apollo::Runners::Knowledge)
      queries = input.fetch(:query_profiles, []).map do |profile|
        selected_profile = profile
        knowledge.handle_query(query: 'migration evidence', requesting_principal_id: 42, min_confidence: 0.0)
      end
      state = { results: results, queries: queries, before: before, persisted: persisted, entries: db[:apollo_entries].order(:id).all }
      puts "APOLLO_RESULT=#{::JSON.generate(state)}"
    RUBY
  end

  def reembedding_state(entries:, **)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, '-Ilib', '-Ispec', '-e', reembedding_script,
      chdir:      File.expand_path('../../../../..', __dir__),
      stdin_data: JSON.generate(entries: entries, **)
    )
    line = stdout.lines.find { |output| output.start_with?('APOLLO_RESULT=') }
    raise "Reembedding process failed: #{stderr}\n#{stdout}" unless status.success? && line

    JSON.parse(line.delete_prefix('APOLLO_RESULT='), symbolize_names: true)
  end

  it 'regenerates legacy documents in resumable bounded batches without changing archived or known-space entries' do
    state = reembedding_state(
      entries: [
        { id: 1, content: 'legacy vector', embedding: '[0.6,0.8]', embedding_dimensions: 2 },
        { id: 2, content: 'legacy missing vector', status: 'candidate' },
        { id: 3, content: 'archived legacy', status: 'archived', embedding: '[0.6,0.8]' },
        { id: 4, content: 'known space', embedding_profile: { model: 'retained', vector: [0.6, 0.8] } }
      ],
      batches: [{ limit: 1 }, { limit: 1, after_id: 1 }, { limit: 1, after_id: 2 }]
    )

    expect(state[:results]).to eq([
                                    { success: true, scanned: 1, updated: 1, skipped: 0, failures: [], next_after_id: 1 },
                                    { success: true, scanned: 1, updated: 1, skipped: 0, failures: [], next_after_id: 2 },
                                    { success: true, scanned: 0, updated: 0, skipped: 0, failures: [], next_after_id: nil }
                                  ])
    state[:entries].first(2).each_with_index do |entry, index|
      expect(JSON.parse(entry[:embedding])).to eq([1.0, 0.0])
      expect(JSON.parse(entry[:embedding_provenance], symbolize_names: true)).to eq(ApolloSpecEmbedding.result[:embedding_provenance])
      expect(entry.except(:embedding, :embedding_space_id, :embedding_dimensions, :embedding_provenance))
        .to eq(state[:before][index].except(:embedding, :embedding_space_id, :embedding_dimensions, :embedding_provenance))
    end
    expect(state[:entries].last(2)).to eq(state[:before].last(2))
  end

  it 'migrates the selected model space and dimensions without altering entry identity, ownership, or content' do
    old_profile = { model: 'old-model', vector: [0.6, 0.8] }
    new_profile = { provider: 'new-provider', model: 'new-model', instance: 'new-instance', vector: [0.2, 0.4, 0.8] }
    old_space = ApolloSpecEmbedding.result(**old_profile)[:embedding_provenance][:space_id]
    state = reembedding_state(
      entries:           [
        { id: 7, content: 'private retained content', content_hash: 'original-hash', access_scope: 'private',
          identity_principal_id: 42, identity_id: 9, identity_canonical_name: 'owner', embedding_profile: old_profile },
        { id: 8, content: 'archived old content', status: 'archived', embedding_profile: old_profile },
        { id: 9, content: 'unselected space', embedding_profile: { model: 'unselected' } }
      ],
      generated_profile: new_profile,
      batches:           [{ legacy_only: false, from_space_id: old_space, provider: 'new-provider', model: 'new-model',
                  instance: 'new-instance', dimensions: 3 }]
    )
    migrated = state[:entries].first
    expected = ApolloSpecEmbedding.result(**new_profile)

    expect(state[:results].first).to include(success: true, scanned: 1, updated: 1, skipped: 0, failures: [])
    expect(JSON.parse(migrated[:embedding])).to eq(expected[:vector])
    expect(JSON.parse(migrated[:embedding_provenance], symbolize_names: true)).to eq(expected[:embedding_provenance])
    expect(migrated).to include(embedding_dimensions: 3, embedding_space_id: expected[:embedding_provenance][:space_id])
    expect(migrated.except(:embedding, :embedding_space_id, :embedding_dimensions, :embedding_provenance))
      .to eq(state[:before].first.except(:embedding, :embedding_space_id, :embedding_dimensions, :embedding_provenance))
    expect(state[:entries].last(2)).to eq(state[:before].last(2))
  end

  it 'reports partial provider failure and keeps the failed vector usable while continuing the batch' do
    old_profile = { model: 'old-model', vector: [0.6, 0.8] }
    state = reembedding_state(
      entries: [{ id: 1, content: 'provider failure', embedding_profile: old_profile },
                { id: 2, content: 'provider success', embedding_profile: old_profile }],
      generated_profile: { model: 'replacement', vector: [0.2, 0.4, 0.8] },
      provider_failures: ['provider failure'], batches: [{ legacy_only: false, limit: 2 }],
      query_profiles: [old_profile, { model: 'replacement', vector: [0.2, 0.4, 0.8] }]
    )

    expect(state[:results].first).to eq(success: false, scanned: 2, updated: 1, skipped: 0, next_after_id: 2,
                                        failures: [{ entry_id: 1, error: 'provider unavailable for document' }])
    expect(state[:persisted].first).to eq(state[:before].first)
    expect(state[:queries]).to all(include(success: true))
    expect(state[:queries].map { |result| result[:entries].map { |entry| entry[:id] } }).to eq([[1], [2]])
    expect(JSON.parse(state[:entries].last[:embedding])).to eq([0.2, 0.4, 0.8])
  end

  it 'does not compare identical coordinates from different models or legacy and different-dimensional spaces' do
    first_profile = { model: 'first-model', vector: [1.0, 0.0] }
    other_profile = { model: 'other-model', vector: [1.0, 0.0] }
    dimension_profile = { model: 'first-model', vector: [1.0, 0.0, 0.0] }
    state = reembedding_state(
      entries:        [{ id: 1, content: 'first space', embedding_profile: first_profile },
                       { id: 2, content: 'other space', embedding_profile: other_profile },
                       { id: 3, content: 'unknown space', embedding: '[1.0,0.0]', embedding_dimensions: 2 },
                       { id: 4, content: 'other dimension', embedding_profile: dimension_profile }],
      query_profiles: [first_profile, other_profile, dimension_profile]
    )

    expect(state[:queries]).to all(include(success: true))
    expect(state[:queries].map { |result| result[:entries].map { |entry| entry[:id] } }).to eq([[1], [2], [4]])
    expect(state[:entries][2]).to eq(state[:before][2])
  end

  it 'does not attach a generated vector to content changed while the provider was working' do
    old_profile = { model: 'old-model', vector: [0.6, 0.8] }
    state = reembedding_state(
      entries:           [{ id: 1, content: 'original content', embedding_profile: old_profile }],
      generated_profile: { model: 'replacement', vector: [0.2, 0.4, 0.8] },
      concurrent_update: { id: 1, content: 'concurrently changed content' },
      batches:           [{ legacy_only: false }]
    )

    expect(state[:results].first).to include(success: true, scanned: 1, updated: 0, skipped: 1, failures: [])
    expect(state[:entries].first).to include(
      content:      'concurrently changed content',
      content_hash: Legion::Extensions::Apollo::Helpers::Writeback.content_hash(content: 'concurrently changed content')
    )
    expect(state[:entries].first.except(:content, :content_hash)).to eq(state[:before].first.except(:content, :content_hash))
  end
end
