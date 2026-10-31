# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/transport/messages/query'

RSpec.describe Legion::Extensions::Apollo::Transport::Messages::Query do
  it 'serializes caller filters, identity, action, and reply metadata on the canonical wire' do
    payload = {
      action: 'retrieve', query: 'PKI configuration', limit: 5, min_confidence: 0.3,
      status: ['confirmed'], tags: %w[vault pki], tag_match: 'all', domain: 'infrastructure',
      agent_id: 'worker-1', requesting_principal_id: 42, exclude_source_agents: ['worker-1'],
      reply_to: 'reply-queue', correlation_id: 'corr-123'
    }
    message = described_class.new(**payload, encrypt: false)

    expect(Legion::JSON.load(message.encode_message)).to eq(payload)
    expect(message.publish_envelope_options(options: payload)).to include(
      routing_key: 'legion.apollo.query', reply_to: 'reply-queue', correlation_id: 'corr-123'
    )
  end

  it 'preserves explicit null status and principal without manufacturing omitted fields' do
    message = described_class.new(action: 'query', query: '', status: nil, requesting_principal_id: nil, encrypt: false)
    payload = Legion::JSON.load(message.encode_message)

    expect(payload).to eq(action: 'query', query: '', status: nil, requesting_principal_id: nil)
  end

  it 'carries traversal parameters without synthesizing a query' do
    payload = { action: 'traverse', entry_id: 'entry-1', depth: 3, relation_types: ['supports'], agent_id: 'worker-1' }

    expect(Legion::JSON.load(described_class.new(**payload, encrypt: false).encode_message)).to eq(payload)
  end
end
