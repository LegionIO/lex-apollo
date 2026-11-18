# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/runners/gas'

RSpec.describe Legion::Extensions::Apollo::Runners::Gas, 'anticipation phase' do
  it 'does not promote private audit content when the LLM is unavailable' do
    allow(Legion::LLM).to receive(:started?).and_return(false)
    allow(described_class).to receive(:settings).and_return(
      Legion::Extensions::Apollo.default_settings.merge(gas: Legion::Extensions::Apollo.default_settings[:gas].merge(enabled: true))
    )
    expect(Legion::Extensions::Apollo::Runners::Knowledge).not_to receive(:handle_ingest)

    result = described_class.process(
      request_id: 'req-anticipate', messages: [{ content: 'question' }], response_content: 'observation',
      access_scope: 'private', identity_principal_id: 42, content_sanitized: true
    )

    expect(result).to include(success: true, phases_completed: 0, reason: 'llm_unavailable')
  end
end
