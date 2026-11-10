# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'legion/extensions/apollo/runners/entity_watchdog'

RSpec.describe Legion::Extensions::Apollo::Runners::EntityWatchdog do
  let(:db) { Sequel.sqlite }
  let(:published) { [] }

  before do
    db.create_table(:task_logs) do
      primary_key :id
      String :entry
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

  def log_entry(text, offset: 0)
    Legion::Data::Model::TaskLog.create(entry: text, created_at: Time.now - offset)
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
