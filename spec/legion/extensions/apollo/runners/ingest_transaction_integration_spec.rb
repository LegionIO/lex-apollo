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
      require 'sequel/extensions/pg_array'
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
        String :content_hash, unique: true
        String :access_scope
        Integer :identity_principal_id
        Integer :identity_id
        String :identity_canonical_name
        String :embedding
        DateTime :created_at
        DateTime :updated_at
        check(Sequel.lit("content != 'entry failure'"))
      end
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
      db[:apollo_entries].insert(input[:existing]) if input[:existing]
      runner = Object.new.extend(Legion::Extensions::Apollo::Runners::Knowledge)
      result = runner.handle_ingest(
        content: input[:content], content_type: :fact, source_agent: input[:source_agent], embedding: nil, **input.fetch(:options, {})
      )
      state = { result: result, entries: db[:apollo_entries].count,
                expertise: db[:apollo_expertise].count, access_logs: db[:apollo_access_log].count,
                records: db[:apollo_entries].all }
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

  it 'does not return or boost a different owner through content-hash deduplication or race recovery' do
    state = ingest_state(
      content:  'identical private content',
      existing: { content: 'identical private content', content_hash: 'shared-hash', status: 'candidate',
                  access_scope: 'private', identity_principal_id: 99, confidence: 0.5 },
      options:  { content_hash: 'shared-hash', access_scope: 'private', identity_principal_id: 42 }
    )

    expect(state[:result]).to include(success: false)
    expect(state[:result]).not_to have_key(:entry_id)
    expect(state).to include(entries: 1, expertise: 0, access_logs: 0)
    expect(state[:records].first).to include(identity_principal_id: 99, confidence: 0.5)
  end
end
