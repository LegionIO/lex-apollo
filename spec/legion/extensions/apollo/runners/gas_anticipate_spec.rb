# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/runners/gas'

RSpec.describe Legion::Extensions::Apollo::Runners::Gas, 'anticipation phase' do
  it 'reports a completed mechanical process without fabricated anticipations when LLM is unavailable' do
    allow(Legion::LLM).to receive(:started?).and_return(false)
    allow(Legion::Extensions::Apollo::Runners::EntityExtractor).to receive(:extract_entities)
      .and_return(success: true, entities: [])
    knowledge = Module.new do
      def self.retrieve_relevant(**)
        { success: true, entries: [], count: 0 }
      end

      def self.handle_ingest(**)
        { success: true, entry_id: 7 }
      end
    end
    stub_const('Legion::Extensions::Apollo::Runners::Knowledge', knowledge)

    result = described_class.process(
      request_id: 'req-anticipate', messages: [{ content: 'question' }], response_content: 'observation'
    )

    expect(result).to include(success: true, phases_completed: 6, anticipations: 0)
  end
end
