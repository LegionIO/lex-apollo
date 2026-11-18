# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'stringio'
require 'logger'
require 'legion/extensions/apollo/runners/entity_watchdog'

RSpec.describe Legion::Extensions::Apollo::Runners::EntityWatchdog do
  let(:db) { Sequel.sqlite }
  let(:published) { [] }

  before do
    allow(described_class).to receive(:settings).and_return(
      Legion::Extensions::Apollo.default_settings.merge(
        entity_watchdog: Legion::Extensions::Apollo.default_settings[:entity_watchdog].merge(enabled: true)
      )
    )
    db.create_table(:task_logs) do
      primary_key :id
      String :entry
      String :access_scope, default: 'global'
      Integer :identity_principal_id
      Integer :identity_id
      DateTime :created_at
    end
    stub_const('Legion::Data::Model::TaskLog', Class.new(Sequel::Model(db[:task_logs])))

    messages = published
    message_class = Class.new do
      define_singleton_method(:published) { messages }
      define_method(:initialize) { |**attributes| @attributes = attributes }
      define_method(:publish!) do
        messages << @attributes
        { accepted: true }
      end
    end
    stub_const('Legion::Extensions::Apollo::Transport::Messages::Ingest', message_class)
    described_class.instance_variable_set(:@entity_watchdog_processed_hashes, {})
  end

  after do
    db.disconnect
    described_class.remove_instance_variable(:@entity_watchdog_processed_hashes) if
      described_class.instance_variable_defined?(:@entity_watchdog_processed_hashes)
  end

  def log_entry(text, offset: 0, access_scope: 'global', identity_principal_id: nil, identity_id: nil)
    Legion::Data::Model::TaskLog.create(entry: text, created_at: Time.now - offset,
                                        access_scope: access_scope, identity_principal_id: identity_principal_id,
                                        identity_id: identity_id)
  end

  def stub_process_identity(principal_id: 42, identity_id: 9)
    stub_const('Legion::Identity', Module.new) unless defined?(Legion::Identity)
    stub_const('Legion::Identity::Process', Class.new do
      define_singleton_method(:db_principal_id) { principal_id }
      define_singleton_method(:db_identity_id) { identity_id }
    end)
  end

  it 'does not query task logs unless explicitly enabled' do
    allow(described_class).to receive(:settings).and_return(Legion::Extensions::Apollo.default_settings)
    log_entry('private task text')
    expect(Legion::Data::Model::TaskLog).not_to receive(:where)

    expect(described_class.scan_and_ingest).to include(success: true, ingested: 0, reason: :disabled)
    expect(published).to be_empty
  end

  it 'filters task logs in SQL before fetching their text' do
    stub_process_identity
    log_entry('global entry')
    log_entry('public entry', access_scope: 'public')
    log_entry('owned by principal', access_scope: 'private', identity_principal_id: 42)
    log_entry('owned by identity', access_scope: 'private', identity_id: 9)
    log_entry('other user private', access_scope: 'private', identity_principal_id: 99)
    log_entry('conflicting owner', access_scope: 'private', identity_principal_id: 99, identity_id: 9)
    log_entry('other team', access_scope: 'team', identity_principal_id: 99)
    sql_output = StringIO.new
    db.loggers << Logger.new(sql_output)

    task_logs = described_class.send(:entity_watchdog_recent_task_logs)

    expect(task_logs).to match_array([
                                       { text: 'global entry', access_scope: 'global', identity_principal_id: nil },
                                       { text: 'public entry', access_scope: 'global', identity_principal_id: nil },
                                       { text: 'owned by principal', access_scope: 'private', identity_principal_id: 42 },
                                       { text: 'owned by identity', access_scope: 'private', identity_principal_id: 42 }
                                     ])
    query = sql_output.string.lines.find { |line| line.include?('SELECT') && line.include?('task_logs') }
    expect(query).to match(/WHERE.*access_scope.*identity_principal_id.*identity_id/)
  end

  it 'queries only global and public logs when no process identity is available' do
    hide_const('Legion::Identity::Process') if defined?(Legion::Identity::Process)
    log_entry('global entry')
    log_entry('private entry', access_scope: 'private', identity_principal_id: 42)

    expect(described_class.send(:entity_watchdog_recent_task_logs)).to eq(
      [{ text: 'global entry', access_scope: 'global', identity_principal_id: nil }]
    )
  end

  it 'keeps entities from an owned private log private on lookup and publication' do
    stub_process_identity
    log_entry('private service note', access_scope: 'private', identity_principal_id: 42)
    allow(Legion::Extensions::Apollo::Runners::EntityExtractor).to receive(:extract_entities)
      .and_return(success: true, source: :llm,
                  entities: [{ name: 'private service', type: 'service', confidence: 0.95 }])
    allow(Legion::Extensions::Apollo::Runners::Knowledge).to receive(:retrieve_relevant)
      .and_return(success: true, entries: [], count: 0)

    expect(described_class.scan_and_ingest).to include(success: true, ingested: 1)
    expect(Legion::Extensions::Apollo::Runners::Knowledge).to have_received(:retrieve_relevant)
      .with(hash_including(requesting_principal_id: 42))
    expect(published).to contain_exactly(hash_including(
                                           content: 'Service: private service', access_scope: 'private',
                                           identity_principal_id: 42
                                         ))
  end

  it 'reports missing TaskLog storage instead of treating it as an empty scan' do
    hide_const('Legion::Data::Model::TaskLog')

    result = described_class.scan_and_ingest

    expect(result).to include(success: false, error: 'task_log_not_available', ingested: 0)
  end

  it 'ingests a new entity from a real TaskLog row and deduplicates only after success' do
    log_entry('deploying lex-synapse')
    allow(Legion::Extensions::Apollo::Runners::EntityExtractor).to receive(:extract_entities)
      .and_return(success: true, source: :llm,
                  entities: [{ name: 'lex-synapse', type: 'repository', confidence: 0.95 }])
    allow(Legion::Extensions::Apollo::Runners::Knowledge).to receive(:retrieve_relevant)
      .and_return(success: true, entries: [], count: 0)

    first = described_class.scan_and_ingest
    second = described_class.scan_and_ingest

    expect(first).to include(success: true, ingested: 1, logs_scanned: 1, failed: 0)
    expect(second).to include(success: true, ingested: 0, logs_scanned: 1, failed: 0)
    expect(Legion::Extensions::Apollo::Runners::EntityExtractor).to have_received(:extract_entities).once
    expect(published).to contain_exactly(hash_including(content: 'Repository: lex-synapse'))
  end

  it 'reports partial acceptance and retries failed texts while retaining successful deduplication' do
    log_entry('successful text')
    log_entry('retry text', offset: 1)
    attempts = Hash.new(0)
    allow(Legion::Extensions::Apollo::Runners::EntityExtractor).to receive(:extract_entities) do |text:, **|
      attempts[text] += 1
      if text == 'retry text' && attempts[text] == 1
        { success: false, entities: [], source: :error }
      else
        { success: true, source: :llm,
          entities: [{ name: text, type: 'concept', confidence: 0.9 }] }
      end
    end
    allow(Legion::Extensions::Apollo::Runners::Knowledge).to receive(:retrieve_relevant)
      .and_return(success: true, entries: [], count: 0)

    first = described_class.scan_and_ingest
    second = described_class.scan_and_ingest

    expect(first).to include(success: false, ingested: 1, logs_scanned: 2, failed: 1)
    expect(second).to include(success: true, ingested: 1, logs_scanned: 2, failed: 0)
    expect(attempts).to eq('successful text' => 1, 'retry text' => 2)
    expect(published.size).to eq(2)
  end

  it 'does not treat a failed entity lookup as absence and retries that text' do
    log_entry('lookup failure')
    allow(Legion::Extensions::Apollo::Runners::EntityExtractor).to receive(:extract_entities)
      .and_return(success: true, source: :llm,
                  entities: [{ name: 'unknown', type: 'concept', confidence: 0.9 }])
    allow(Legion::Extensions::Apollo::Runners::Knowledge).to receive(:retrieve_relevant)
      .and_return(success: false, error: 'database unavailable')

    first = described_class.scan_and_ingest
    second = described_class.scan_and_ingest

    expect(first).to include(success: false, ingested: 0, failed: 1)
    expect(second).to include(success: false, ingested: 0, failed: 1)
    expect(Legion::Extensions::Apollo::Runners::EntityExtractor).to have_received(:extract_entities).twice
    expect(published).to be_empty
  end

  it 'keeps a publication failure retryable' do
    log_entry('publication failure')
    allow(Legion::Extensions::Apollo::Runners::EntityExtractor).to receive(:extract_entities)
      .and_return(success: true, source: :llm,
                  entities: [{ name: 'broken', type: 'service', confidence: 0.9 }])
    allow(Legion::Extensions::Apollo::Runners::Knowledge).to receive(:retrieve_relevant)
      .and_return(success: true, entries: [], count: 0)
    message = Legion::Extensions::Apollo::Transport::Messages::Ingest
    allow(message).to receive(:new).and_raise(IOError, 'broker unavailable')

    result = described_class.scan_and_ingest

    expect(result).to include(success: false, ingested: 0, failed: 1)
    expect(Legion::Extensions::Apollo::Runners::EntityExtractor).to have_received(:extract_entities).once
  end
end
