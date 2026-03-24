# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/runners/gas'

RSpec.describe Legion::Extensions::Apollo::Runners::Gas do
  describe '.process' do
    let(:audit_event) do
      {
        request_id: 'req_abc',
        messages: [{ role: :user, content: 'How does pgvector work?' }],
        response_content: 'pgvector uses HNSW indexes for approximate nearest neighbor search.',
        routing: { provider: :anthropic, model: 'claude-opus-4-6' },
        tokens: { input: 50, output: 30, total: 80 },
        caller: { requested_by: { identity: 'user:matt', type: :user } },
        timestamp: Time.now
      }
    end

    it 'runs all 6 phases in order' do
      allow(described_class).to receive(:phase_comprehend).and_return([{ content: 'fact', content_type: :fact }])
      allow(described_class).to receive(:phase_extract).and_return([{ name: 'pgvector', type: 'technology' }])
      allow(described_class).to receive(:phase_relate).and_return([])
      allow(described_class).to receive(:phase_synthesize).and_return([])
      allow(described_class).to receive(:phase_deposit).and_return({ deposited: 1 })
      allow(described_class).to receive(:phase_anticipate).and_return([])

      result = described_class.process(audit_event)
      expect(result).to be_a(Hash)
      expect(result[:phases_completed]).to eq(6)
    end

    it 'skips when audit event has no content' do
      result = described_class.process({ request_id: 'req_abc' })
      expect(result[:phases_completed]).to eq(0)
    end

    it 'skips when response_content is nil' do
      result = described_class.process({ request_id: 'req_abc', messages: [{ role: :user, content: 'hi' }] })
      expect(result[:phases_completed]).to eq(0)
    end

    it 'returns error details on failure' do
      allow(described_class).to receive(:phase_comprehend).and_raise(StandardError, 'boom')

      result = described_class.process(audit_event)
      expect(result[:phases_completed]).to eq(0)
      expect(result[:error]).to eq('boom')
    end
  end

  describe '.processable?' do
    it 'returns true with messages and response_content' do
      event = { messages: [{ role: :user, content: 'hi' }], response_content: 'hello' }
      expect(described_class.processable?(event)).to be true
    end

    it 'returns false without messages' do
      expect(described_class.processable?({ response_content: 'hello' })).to be false
    end

    it 'returns false without response_content' do
      expect(described_class.processable?({ messages: [{ role: :user, content: 'hi' }] })).to be false
    end
  end

  describe '.mechanical_comprehend' do
    it 'wraps response as a single observation' do
      messages = [{ role: :user, content: 'hi' }]
      result = described_class.mechanical_comprehend(messages, 'pgvector is fast')
      expect(result).to eq([{ content: 'pgvector is fast', content_type: :observation }])
    end
  end

  describe '.phase_extract' do
    it 'returns empty array when EntityExtractor not defined' do
      hide_const('Legion::Extensions::Apollo::Runners::EntityExtractor') if defined?(Legion::Extensions::Apollo::Runners::EntityExtractor)
      result = described_class.phase_extract({ response_content: 'test' }, [])
      expect(result).to eq([])
    end
  end

  describe '.phase_relate' do
    it 'returns empty array (stub)' do
      expect(described_class.phase_relate([], [])).to eq([])
    end
  end

  describe '.phase_synthesize' do
    it 'returns empty array (stub)' do
      expect(described_class.phase_synthesize([], [])).to eq([])
    end
  end

  describe '.phase_anticipate' do
    it 'returns empty array (stub)' do
      expect(described_class.phase_anticipate([], [])).to eq([])
    end
  end

  describe '.phase_deposit' do
    it 'returns deposited 0 when Knowledge not defined' do
      hide_const('Legion::Extensions::Apollo::Runners::Knowledge') if defined?(Legion::Extensions::Apollo::Runners::Knowledge)
      result = described_class.phase_deposit([], [], [], [], { request_id: 'req_1' })
      expect(result).to eq({ deposited: 0 })
    end
  end
end
