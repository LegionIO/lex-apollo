# frozen_string_literal: true

require 'spec_helper'

require 'legion/extensions/apollo/transport/exchanges/apollo'
require 'legion/extensions/apollo/transport/messages/writeback'

RSpec.describe Legion::Extensions::Apollo::Transport::Messages::Writeback do
  let(:base_opts) do
    { content: 'test knowledge', content_type: 'observation',
      tags: %w[test], source_agent: 'claude-sonnet-4-6',
      submitted_by: 'user@example.com', submitted_from: 'node-1' }
  end

  describe '#routing_key' do
    it 'routes to store when embedding present' do
      msg = described_class.new(**base_opts, has_embedding: true, embedding: [0.1] * 1024)
      expect(msg.routing_key).to eq('legion.apollo.writeback.store')
    end

    it 'routes to vectorize when no embedding' do
      msg = described_class.new(**base_opts, has_embedding: false)
      expect(msg.routing_key).to eq('legion.apollo.writeback.vectorize')
    end
  end

  describe '#message' do
    it 'serializes producer ownership and provenance with a JSON envelope on both routes' do
      metadata = {
        access_scope: 'private', identity_principal_id: 31, identity_id: nil,
        identity_canonical_name: 'producer@example.test', source_provider: 'anthropic',
        source_channel: 'chat', content_hash: 'digest'
      }
      [true, false].each do |has_embedding|
        options = base_opts.merge(metadata).merge(has_embedding: has_embedding, encrypt: false)
        message = described_class.new(**options)

        expect(Legion::JSON.load(message.encode_message)).to include(base_opts.merge(metadata))
        expect(message.publish_envelope_options(options)).to include(content_type: 'application/json')
      end
    end
  end

  describe '#validate' do
    it 'raises on missing content' do
      expect { described_class.new(**base_opts, content: nil) }.to raise_error(TypeError)
    end
  end
end
