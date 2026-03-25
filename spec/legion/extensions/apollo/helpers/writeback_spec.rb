# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/helpers/tag_normalizer'
require 'legion/extensions/apollo/helpers/writeback'

RSpec.describe Legion::Extensions::Apollo::Helpers::Writeback do
  let(:base_request) do
    double('Request',
           messages: [{ role: 'user', content: 'How does RabbitMQ clustering work?' }],
           caller:   { requested_by: { identity: 'user@example.com', type: :human } })
  end

  let(:base_response) do
    double('Response',
           message:    { content: 'RabbitMQ clustering works by...' * 20 },
           model:      'claude-sonnet-4-6',
           tool_calls: [])
  end

  describe '.should_capture?' do
    it 'returns false for short responses' do
      short = double('Response', message: { content: 'yes' }, tool_calls: [])
      expect(described_class.should_capture?(base_request, short, {})).to be false
    end

    it 'returns false when no research tools were used' do
      expect(described_class.should_capture?(base_request, base_response, {})).to be false
    end

    it 'returns true when research tools were used' do
      enrichments = { 'tool_calls' => [{ name: 'read_file' }] }
      long_response = double('Response',
                             message:    { content: 'x' * 100 },
                             model:      'claude-sonnet-4-6',
                             tool_calls: [{ name: 'read_file' }])
      expect(described_class.should_capture?(base_request, long_response, enrichments)).to be true
    end

    it 'returns false for echo chamber (apollo had results, no additional research)' do
      enrichments = {
        'rag_context:apollo_results' => { count: 3 },
        'tool_calls'                 => []
      }
      long_response = double('Response', message: { content: 'x' * 100 }, tool_calls: [])
      expect(described_class.should_capture?(base_request, long_response, enrichments)).to be false
    end
  end

  describe '.build_payload' do
    it 'builds payload with identity context' do
      payload = described_class.build_payload(
        request:        base_request,
        response:       base_response,
        source_channel: 'chat'
      )
      expect(payload[:submitted_by]).to eq('user@example.com')
      expect(payload[:source_agent]).to eq('claude-sonnet-4-6')
      expect(payload[:content_type]).to eq('observation')
      expect(payload[:source_channel]).to eq('chat_synthesis')
    end

    it 'truncates content to max length' do
      long_response = double('Response',
                             message: { content: 'x' * 10_000 },
                             model:   'test')
      payload = described_class.build_payload(request: base_request, response: long_response)
      expect(payload[:content].length).to be <= 4000
    end

    it 'includes content_hash' do
      payload = described_class.build_payload(request: base_request, response: base_response)
      expect(payload[:content_hash]).to be_a(String)
      expect(payload[:content_hash].length).to eq(32)
    end

    it 'normalizes tags' do
      payload = described_class.build_payload(request: base_request, response: base_response)
      expect(payload[:tags]).to all(match(/\A[a-z0-9-]+\z/))
    end
  end

  describe '.content_hash' do
    it 'produces consistent hashes for same content' do
      hash1 = described_class.content_hash('hello world')
      hash2 = described_class.content_hash('hello world')
      expect(hash1).to eq(hash2)
    end

    it 'normalizes whitespace before hashing' do
      hash1 = described_class.content_hash('hello  world')
      hash2 = described_class.content_hash('hello world')
      expect(hash1).to eq(hash2)
    end
  end
end
