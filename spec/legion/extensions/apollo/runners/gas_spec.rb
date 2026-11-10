# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/runners/gas'

RSpec.describe Legion::Extensions::Apollo::Runners::Gas do
  let(:audit_event) do
    {
      request_id:       'req-1',
      messages:         [{ role: :user, content: 'What is pgvector?' }],
      response_content: 'pgvector uses HNSW indexes.',
      routing:          { provider: :test }
    }
  end

  before do
    allow(Legion::Extensions::Apollo::Runners::EntityExtractor).to receive(:extract_entities)
      .and_return(success: true, entities: [{ name: 'pgvector', type: 'repository' }])
  end

  it 'skips events without an exchange response' do
    result = described_class.process(request_id: 'req-1', messages: [])

    expect(result).to include(success: true, phases_completed: 0, reason: 'no content')
  end

  it 'runs the mechanical pipeline and counts a successful deposit' do
    knowledge = Module.new do
      def self.retrieve_relevant(**)
        { success: true, entries: [], count: 0 }
      end

      def self.handle_ingest(content:, **)
        { success: true, entry_id: content.hash }
      end
    end
    stub_const('Legion::Extensions::Apollo::Runners::Knowledge', knowledge)
    allow(Legion::LLM).to receive(:started?).and_return(false)

    result = described_class.process(**audit_event)

    expect(result).to include(success: true, phases_completed: 6, facts: 1, entities: 1,
                              relations: 0, synthesis: 0, anticipations: 0)
    expect(result[:deposited]).to include(deposited: 1, failed: 0, facts: 1)
  end

  it 'reports partial deposit failure without claiming success' do
    knowledge = Module.new do
      def self.retrieve_relevant(**)
        { success: true, entries: [], count: 0 }
      end

      def self.handle_ingest(**)
        { success: false, error: 'write rejected' }
      end
    end
    stub_const('Legion::Extensions::Apollo::Runners::Knowledge', knowledge)
    allow(Legion::LLM).to receive(:started?).and_return(false)

    result = described_class.process(**audit_event)

    expect(result[:success]).to be false
    expect(result[:phases_completed]).to eq(6)
    expect(result[:deposited]).to include(deposited: 0, failed: 1)
  end

  it 'returns a structured failure when a dependency raises' do
    allow(Legion::Extensions::Apollo::Runners::Knowledge).to receive(:retrieve_relevant)
      .and_raise(IOError, 'retrieval unavailable')
    allow(Legion::LLM).to receive(:started?).and_return(false)

    result = described_class.process(**audit_event)

    expect(result).to include(success: false, phases_completed: 0, error: 'retrieval unavailable')
  end
end
