# frozen_string_literal: true

require 'spec_helper'

unless defined?(Legion::Transport::Message)
  module Legion
    module Transport
      class Message
        attr_reader :options

        def initialize(**opts)
          @options = opts
        end

        def publish
          { published: true }
        end
      end

      class Exchange
        def exchange_name
          'mock'
        end
      end
    end
  end
  $LOADED_FEATURES << 'legion/transport/message' unless $LOADED_FEATURES.include?('legion/transport/message')
  $LOADED_FEATURES << 'legion/transport/exchange' unless $LOADED_FEATURES.include?('legion/transport/exchange')
end

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
    it 'includes identity fields' do
      msg = described_class.new(**base_opts)
      payload = msg.message
      expect(payload[:submitted_by]).to eq('user@example.com')
      expect(payload[:submitted_from]).to eq('node-1')
      expect(payload[:source_agent]).to eq('claude-sonnet-4-6')
    end

    it 'compacts nil values' do
      msg = described_class.new(**base_opts, embedding: nil, knowledge_domain: nil)
      expect(msg.message).not_to have_key(:embedding)
      expect(msg.message).not_to have_key(:knowledge_domain)
    end
  end

  describe '#type' do
    it 'returns apollo_writeback' do
      msg = described_class.new(**base_opts)
      expect(msg.type).to eq('apollo_writeback')
    end
  end

  describe '#validate' do
    it 'raises on missing content' do
      expect { described_class.new(**base_opts, content: nil) }.to raise_error(TypeError)
    end

    it 'passes with valid content' do
      msg = described_class.new(**base_opts)
      msg.validate
      expect(msg.instance_variable_get(:@valid)).to be true
    end
  end
end
