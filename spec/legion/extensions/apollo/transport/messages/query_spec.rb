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
require 'legion/extensions/apollo/transport/messages/query'

RSpec.describe Legion::Extensions::Apollo::Transport::Messages::Query do
  let(:message) do
    described_class.new(
      action:         :query,
      query:          'PKI configuration',
      limit:          5,
      min_confidence: 0.3,
      reply_to:       'reply-queue',
      correlation_id: 'corr-123'
    )
  end

  describe '#routing_key' do
    it 'returns apollo.query' do
      expect(message.routing_key).to eq('apollo.query')
    end
  end

  describe '#message' do
    it 'includes query params' do
      msg = message.message
      expect(msg[:action]).to eq(:query)
      expect(msg[:query]).to eq('PKI configuration')
      expect(msg[:limit]).to eq(5)
      expect(msg[:reply_to]).to eq('reply-queue')
      expect(msg[:correlation_id]).to eq('corr-123')
    end

    it 'compacts nil values' do
      simple = described_class.new(action: :query, query: 'test')
      msg = simple.message
      expect(msg).not_to have_key(:tags)
      expect(msg).not_to have_key(:relation_types)
    end
  end

  describe '#type' do
    it 'returns apollo_query' do
      expect(message.type).to eq('apollo_query')
    end
  end
end
