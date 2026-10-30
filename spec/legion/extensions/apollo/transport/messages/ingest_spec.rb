# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/transport/messages/ingest'

RSpec.describe Legion::Extensions::Apollo::Transport::Messages::Ingest do
  it 'serializes ownership, provenance, context, and a supplied embedding without losing fields' do
    payload = {
      content: 'test fact', content_type: 'fact', tags: ['vault'], source_agent: 'worker-1',
      source_provider: 'anthropic', source_channel: 'chat', knowledge_domain: 'security',
      submitted_by: 'operator', submitted_from: 'terminal', content_hash: 'digest',
      context: { request_id: 'request-1' }, access_scope: 'private', identity_principal_id: 17,
      identity_id: 23, identity_canonical_name: 'operator@example.test', embedding: [0.1, 0.2],
      reply_to: 'reply-queue', correlation_id: 'ingest-123'
    }
    message = described_class.new(**payload, encrypt: false)

    expect(Legion::JSON.load(message.encode_message)).to eq(payload)
    expect(message.publish_envelope_options(payload)).to include(
      routing_key: 'legion.apollo.ingest', content_type: 'application/json', reply_to: 'reply-queue', correlation_id: 'ingest-123'
    )
  end

  it 'does not synthesize identity keys for an omitted producer identity' do
    message = described_class.new(content: 'test', content_type: 'fact', encrypt: false)
    payload = Legion::JSON.load(message.encode_message)

    expect(payload).not_to have_key(:identity_principal_id)
    expect(payload).not_to have_key(:identity_id)
    expect(payload).not_to have_key(:identity_canonical_name)
  end

  it 'preserves explicit null identity so service defaults cannot replace the producer choice' do
    identity = { identity_principal_id: nil, identity_id: nil, identity_canonical_name: nil }
    message = described_class.new(content: 'test', content_type: 'fact', **identity, encrypt: false)

    expect(Legion::JSON.load(message.encode_message)).to include(identity)
  end
end
