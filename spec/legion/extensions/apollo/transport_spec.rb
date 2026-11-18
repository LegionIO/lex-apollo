# frozen_string_literal: true

require 'spec_helper'

unless defined?(Legion::Extensions::Transport)
  module Legion
    module Extensions
      module Transport; end
    end
  end
end

require 'legion/extensions/apollo/transport'

RSpec.describe Legion::Extensions::Apollo::Transport do
  describe '.additional_e_to_q' do
    it 'omits the raw audit binding when GAS is disabled' do
      allow(Legion::Extensions::Apollo).to receive(:settings).and_return(gas: { enabled: false })

      expect(described_class.additional_e_to_q.map { |binding| binding[:routing_key] }).not_to include('llm.audit.complete')
    end

    it 'binds the audit queue when GAS is enabled' do
      allow(Legion::Extensions::Apollo).to receive(:settings).and_return(gas: { enabled: true })

      expect(described_class.additional_e_to_q).to include(
        from:        Legion::Extensions::Apollo::Transport::Exchanges::LlmAudit,
        to:          Legion::Extensions::Apollo::Transport::Queues::GasSubscriber,
        routing_key: 'llm.audit.complete'
      )
    end
  end
end
