# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/runners/gas'

RSpec.describe Legion::Extensions::Apollo::Runners::Gas, 'synthesis phase' do
  it 'does not fabricate derivative entries from a single mechanical observation' do
    allow(Legion::LLM).to receive(:started?).and_return(false)
    allow(Legion::Extensions::Apollo::Runners::EntityExtractor).to receive(:extract_entities)
      .and_return(success: true, entities: [])
    knowledge = Module.new do
      def self.retrieve_relevant(**)
        { success: true, entries: [], count: 0 }
      end

      def self.handle_ingest(**)
        { success: true, entry_id: 8 }
      end
    end
    stub_const('Legion::Extensions::Apollo::Runners::Knowledge', knowledge)

    result = described_class.process(
      request_id: 'req-synthesize', messages: [{ content: 'question' }], response_content: 'observation'
    )

    expect(result).to include(success: true, phases_completed: 6, facts: 1, synthesis: 0)
    expect(result[:deposited]).to include(synthesis: 0)
  end
end
