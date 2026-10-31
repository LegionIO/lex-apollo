# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'
require 'json'

RSpec.describe 'Apollo ingest transaction' do
  let(:ingest_script) do
    <<~'RUBY'
      require 'sequel'
      require 'rspec'
      require 'spec_helper'
      require 'json'
      require 'legion/extensions/apollo/runners/knowledge'
      db = Sequel.sqlite
      db.create_table(:apollo_entries) do
        primary_key :id
        String :content
        String :content_type
        Float :confidence
        String :source_agent
        String :source_provider
        String :source_channel
        String :source_context
        String :tags
        String :status
        String :knowledge_domain
        String :submitted_by
        String :submitted_from
        String :content_hash
        String :access_scope
        Integer :identity_principal_id
        Integer :identity_id
        String :identity_canonical_name
        String :embedding
        String :embedding_space_id
        Integer :embedding_dimensions
        String :embedding_provenance
        DateTime :created_at
        DateTime :updated_at
        check(Sequel.lit("content != 'entry failure'"))
      end
      db.run <<~SQL
        CREATE UNIQUE INDEX idx_apollo_content_hash_owner ON apollo_entries (
          content_hash, access_scope,
          (CASE WHEN access_scope = 'global' THEN 0 ELSE COALESCE(identity_principal_id, 0) END)
        ) WHERE status != 'archived' AND content_hash IS NOT NULL
      SQL
      db.create_table(:apollo_expertise) do
        primary_key :id
        String :agent_id
        String :domain
        Float :proficiency
        Integer :entry_count
        DateTime :last_active_at
        check(Sequel.lit("agent_id != 'fail-expertise'"))
      end
      db.create_table(:apollo_access_log) do
        primary_key :id
        Integer :entry_id
        String :agent_id
        String :action
        check(Sequel.lit("agent_id != 'fail-audit'"))
      end
      input = ::JSON.parse($stdin.read, symbolize_names: true)
      Legion.const_set(:LLM, Module.new) unless defined?(Legion::LLM)
      Legion::LLM.const_set(:Call, Module.new) unless defined?(Legion::LLM::Call)
      Legion::LLM::Call.const_set(:Embeddings, Module.new) unless defined?(Legion::LLM::Call::Embeddings)
      generated = []
      Legion::LLM::Call::Embeddings.define_singleton_method(:generate) do |text:, task:, **|
        generated << { text: text, task: task }
        raise 'embedding provider unavailable' if input[:generation_error]

        ApolloSpecEmbedding.result(task: task)
      end
      Legion::Data.const_set(:Model, Module.new) unless defined?(Legion::Data::Model)
      Legion::Data::Model.const_set(:Apollo, Module.new)
      { Entry: :apollo_entries, Expertise: :apollo_expertise, AccessLog: :apollo_access_log }.each do |name, table|
        next if name == input[:missing]&.to_sym

        Legion::Data::Model::Apollo.const_set(name, Class.new(Sequel::Model(db[table])))
      end
      if input[:process_identity]
        Legion.const_set(:Identity, Module.new) unless defined?(Legion::Identity)
        Legion::Identity.const_set(:Process, Module.new)
        Legion::Identity::Process.define_singleton_method(:db_principal_id) { 999 }
        Legion::Identity::Process.define_singleton_method(:db_identity_id) { 998 }
        Legion::Identity::Process.define_singleton_method(:canonical_name) { 'service-node' }
      end
      if input[:existing]
        existing = input[:existing]
        unless input[:legacy]
          embedding = ApolloSpecEmbedding.result
          existing = existing.merge(embedding: ::JSON.generate(embedding[:vector]),
                                    embedding_space_id: embedding[:embedding_provenance][:space_id],
                                    embedding_dimensions: embedding[:dimensions],
                                    embedding_provenance: ::JSON.generate(embedding[:embedding_provenance]))
        end
        db[:apollo_entries].insert(existing)
      end
      before = db[:apollo_entries].all
      runner = Object.new.extend(Legion::Extensions::Apollo::Runners::Knowledge)
      result = runner.handle_ingest(
        content: input[:content], content_type: :fact, source_agent: input[:source_agent], embedding: nil, **input.fetch(:options, {})
      )
      state = { result: result, entries: db[:apollo_entries].count,
                expertise: db[:apollo_expertise].count, access_logs: db[:apollo_access_log].count,
                records: db[:apollo_entries].order(:id).all, before: before, generated: generated }
      puts "APOLLO_RESULT=#{::JSON.generate(state)}"
    RUBY
  end

  def ingest_state(content:, source_agent: 'success', missing: nil, **options)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, '-Ilib', '-Ispec', '-e', ingest_script,
      chdir:      File.expand_path('../../../../..', __dir__),
      stdin_data: JSON.generate({ content: content, source_agent: source_agent, missing: missing }.merge(options))
    )
    line = stdout.lines.find { |output| output.start_with?('APOLLO_RESULT=') }
    raise "Ingest transaction process failed: #{stderr}\n#{stdout}" unless status.success? && line

    JSON.parse(line.delete_prefix('APOLLO_RESULT='), symbolize_names: true)
  end

  it 'commits the entry, expertise bookkeeping, and access log as one successful ingest' do
    state = ingest_state(content: 'committed knowledge')

    expect(state[:result]).to include(success: true, status: 'candidate')
    expect(state).to include(entries: 1, expertise: 1, access_logs: 1)
  end

  it 'rolls back all persistence when any synchronous ingest side effect fails' do
    entry_failure = ingest_state(content: 'entry failure')
    expertise_failure = ingest_state(content: 'expertise failure', source_agent: 'fail-expertise')
    audit_failure = ingest_state(content: 'audit failure', source_agent: 'fail-audit')

    [entry_failure, expertise_failure, audit_failure].each do |state|
      expect(state[:result]).to include(success: false)
      expect(state).to include(entries: 0, expertise: 0, access_logs: 0)
    end
  end

  it 'rejects missing required auxiliary models before creating the primary entry' do
    missing_expertise = ingest_state(content: 'unavailable expertise', missing: :Expertise)
    missing_access_log = ingest_state(content: 'unavailable access log', missing: :AccessLog)

    [missing_expertise, missing_access_log].each do |state|
      expect(state[:result]).to include(success: false, error: 'apollo_data_not_available')
      expect(state).to include(entries: 0, expertise: 0, access_logs: 0)
    end
  end

  it 'retains process-owned ingestion for trusted direct calls without explicit producer identity' do
    state = ingest_state(content: 'service-owned knowledge', process_identity: true, options: { access_scope: 'private' })

    expect(state[:result]).to include(success: true)
    expect(state[:records].first).to include(access_scope: 'private', identity_principal_id: 999,
                                             identity_id: 998, identity_canonical_name: 'service-node')
  end

  it 'persists the producer identity instead of the receiving service identity' do
    state = ingest_state(content: 'private producer knowledge', process_identity: true,
                         options: { access_scope: 'private', identity_principal_id: 42, identity_id: 7,
                                    identity_canonical_name: 'producer' })

    expect(state[:result]).to include(success: true)
    expect(state[:records].first).to include(access_scope: 'private', identity_principal_id: 42,
                                             identity_id: 7, identity_canonical_name: 'producer')
  end

  it 'does not substitute service identity when the caller explicitly has no identity' do
    state = ingest_state(content: 'anonymous public knowledge', process_identity: true,
                         options: { identity_principal_id: nil, identity_id: nil, identity_canonical_name: nil })

    expect(state[:result]).to include(success: true)
    expect(state[:records].first).to include(identity_principal_id: nil, identity_id: nil, identity_canonical_name: nil)
  end

  it 'rejects restricted ingestion without an owner before writing anything' do
    state = ingest_state(content: 'unowned private knowledge',
                         options: { access_scope: 'private', identity_principal_id: nil })

    expect(state[:result]).to include(success: false, error: 'identity_required')
    expect(state).to include(entries: 0, expertise: 0, access_logs: 0)
  end

  it 'persists identical private hashes separately without touching the other owner' do
    state = ingest_state(
      content:  'identical private content',
      existing: { content: 'identical private content', content_hash: 'shared-hash', status: 'candidate',
                  access_scope: 'private', identity_principal_id: 99, confidence: 0.5 },
      options:  { content_hash: 'shared-hash', access_scope: 'private', identity_principal_id: 42 }
    )

    expect(state[:result]).to include(success: true)
    expect(state).to include(entries: 2, expertise: 1, access_logs: 1)
    expect(state[:records].first).to eq(state[:before].first)
    expect(state[:records].last).to include(id: state[:result][:entry_id], content: 'identical private content',
                                            content_hash: 'shared-hash', identity_principal_id: 42, access_scope: 'private')
  end

  it 'deduplicates within one owner without creating auxiliary rows or regenerating a valid vector' do
    state = ingest_state(
      content:  'same owner content',
      existing: { id: 7, content: 'same owner content', content_hash: 'owned-hash', status: 'candidate',
                  access_scope: 'private', identity_principal_id: 42, confidence: 0.5 },
      options:  { content_hash: 'owned-hash', access_scope: 'private', identity_principal_id: 42 }
    )

    expect(state[:result]).to include(success: true, entry_id: 7, deduped: true)
    expect(state).to include(entries: 1, expertise: 0, access_logs: 0, generated: [])
    expect(state[:records].first[:confidence]).to be > 0.5
    expect(state[:records].first.except(:confidence, :updated_at))
      .to eq(state[:before].first.except(:confidence, :updated_at))
  end

  it 'regenerates legacy duplicates before success and leaves them unchanged if the provider fails' do
    options = {
      content:  'legacy duplicate',
      legacy:   true,
      existing: { id: 7, content: 'legacy duplicate', content_hash: 'legacy-hash', status: 'candidate',
                  access_scope: 'private', identity_principal_id: 42, confidence: 0.5, embedding: '[0.6,0.8]' },
      options:  { content_hash: 'legacy-hash', access_scope: 'private', identity_principal_id: 42 }
    }
    repaired = ingest_state(**options)
    failed = ingest_state(**options, generation_error: true)

    expect(repaired[:result]).to include(success: true, entry_id: 7, deduped: true)
    expect(repaired).to include(entries: 1, expertise: 0, access_logs: 0,
                                generated: [{ text: 'legacy duplicate', task: 'document' }])
    expect(JSON.parse(repaired[:records].first[:embedding])).to eq([1.0, 0.0])
    expect(JSON.parse(repaired[:records].first[:embedding_provenance], symbolize_names: true))
      .to eq(ApolloSpecEmbedding.result[:embedding_provenance])
    expect(failed[:result]).to include(success: false, error: 'embedding provider unavailable')
    expect(failed[:records]).to eq(failed[:before])
    expect(failed).to include(entries: 1, expertise: 0, access_logs: 0)
  end

  it 'writes nothing when embedding generation fails for new content' do
    state = ingest_state(content: 'provider failure', generation_error: true)

    expect(state[:result]).to include(success: false, error: 'embedding provider unavailable')
    expect(state).to include(entries: 0, expertise: 0, access_logs: 0)
  end
end
