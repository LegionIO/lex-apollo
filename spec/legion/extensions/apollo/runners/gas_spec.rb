# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/runners/gas'

RSpec.describe Legion::Extensions::Apollo::Runners::Gas do
  let(:audit_event) do
    {
      request_id:            'req-1',
      messages:              [{ role: :user, content: 'What is pgvector?' }],
      response_content:      'pgvector uses HNSW indexes.',
      routing:               { provider: :test },
      access_scope:          'private',
      identity_principal_id: 42,
      content_sanitized:     true
    }
  end

  before do
    allow(described_class).to receive(:settings).and_return(
      Legion::Extensions::Apollo.default_settings.merge(gas: Legion::Extensions::Apollo.default_settings[:gas].merge(enabled: true))
    )
    allow(Legion::Extensions::Apollo::Runners::EntityExtractor).to receive(:extract_entities)
      .and_return(success: true, entities: [{ name: 'pgvector', type: 'repository' }])
  end

  it 'skips events without an exchange response' do
    result = described_class.process(request_id: 'req-1', messages: [])

    expect(result).to include(success: true, phases_completed: 0, reason: 'no content')
  end

  it 'does not process audit events by default' do
    allow(described_class).to receive(:settings).and_return(Legion::Extensions::Apollo.default_settings)
    expect(Legion::Extensions::Apollo::Runners::Knowledge).not_to receive(:handle_ingest)

    expect(described_class.process(**audit_event)).to include(success: true, phases_completed: 0, reason: 'disabled')
  end

  it 'rejects audit events without explicit private ownership and sanitized content' do
    expect(Legion::Extensions::Apollo::Runners::Knowledge).not_to receive(:handle_ingest)

    [audit_event.except(:identity_principal_id), audit_event.merge(access_scope: 'global'),
     audit_event.except(:content_sanitized), audit_event.merge(response_content: 'Contact alice@example.com')].each do |event|
      expect(described_class.process(**event)).to include(success: true, phases_completed: 0, reason: 'unsafe_audit_event')
    end
  end

  it 'does not deposit the raw response when the LLM is unavailable' do
    allow(Legion::LLM).to receive(:started?).and_return(false)
    expect(Legion::Extensions::Apollo::Runners::Knowledge).not_to receive(:handle_ingest)

    expect(described_class.process(**audit_event)).to include(success: true, phases_completed: 0, reason: 'llm_unavailable')
  end

  it 'stores clean derived facts privately and scopes semantic lookup to the caller' do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(described_class).to receive(:gas_llm_comprehend)
      .and_return([{ content: 'HNSW is an approximate search index', content_type: :fact }])
    allow(Legion::Extensions::Apollo::Runners::Knowledge).to receive(:retrieve_relevant)
      .and_return(success: true, entries: [], count: 0)
    allow(Legion::Extensions::Apollo::Runners::Knowledge).to receive(:handle_ingest)
      .and_return(success: true, entry_id: 7)

    result = described_class.process(**audit_event)

    expect(result).to include(success: true, phases_completed: 6, facts: 1, anticipations: 0)
    expect(result[:deposited]).to include(deposited: 1, failed: 0, facts: 1)
    expect(Legion::Extensions::Apollo::Runners::Knowledge).to have_received(:retrieve_relevant)
      .with(hash_including(requesting_principal_id: 42))
    expect(Legion::Extensions::Apollo::Runners::Knowledge).to have_received(:handle_ingest)
      .with(hash_including(access_scope: 'private', identity_principal_id: 42,
                           content: 'HNSW is an approximate search index'))
  end

  it 'skips sensitive generated facts before lookup or deposit' do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(described_class).to receive(:gas_llm_comprehend)
      .and_return([{ content: 'alice@example.com', content_type: :fact }])
    expect(Legion::Extensions::Apollo::Runners::Knowledge).not_to receive(:retrieve_relevant)
    expect(Legion::Extensions::Apollo::Runners::Knowledge).not_to receive(:handle_ingest)

    expect(described_class.process(**audit_event)).to include(success: true, facts: 0)
  end

  it 'reports partial deposit failure without claiming success' do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(described_class).to receive(:gas_llm_comprehend)
      .and_return([{ content: 'HNSW is an approximate search index', content_type: :fact }])
    allow(Legion::Extensions::Apollo::Runners::Knowledge).to receive(:retrieve_relevant)
      .and_return(success: true, entries: [], count: 0)
    allow(Legion::Extensions::Apollo::Runners::Knowledge).to receive(:handle_ingest)
      .and_return(success: false, error: 'write rejected')

    result = described_class.process(**audit_event)

    expect(result).to include(success: false, phases_completed: 6)
    expect(result[:deposited]).to include(deposited: 0, failed: 1)
  end

  it 'returns a structured failure when a dependency raises' do
    allow(Legion::Extensions::Apollo::Runners::Knowledge).to receive(:retrieve_relevant)
      .and_raise(IOError, 'retrieval unavailable')
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(described_class).to receive(:gas_llm_comprehend)
      .and_return([{ content: 'HNSW is an approximate search index', content_type: :fact }])

    result = described_class.process(**audit_event)

    expect(result).to include(success: false, phases_completed: 0, error: 'retrieval unavailable')
  end
end
