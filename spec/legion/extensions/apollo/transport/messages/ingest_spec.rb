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
require 'legion/extensions/apollo/transport/messages/ingest'

RSpec.describe Legion::Extensions::Apollo::Transport::Messages::Ingest do
  let(:message) do
    described_class.new(
      content:      'test fact',
      content_type: :fact,
      tags:         %w[vault],
      source_agent: 'worker-1'
    )
  end

  describe '#routing_key' do
    it 'returns legion.apollo.ingest' do
      expect(message.routing_key).to eq('legion.apollo.ingest')
    end
  end

  describe '#message' do
    it 'includes content and metadata' do
      msg = message.message
      expect(msg[:content]).to eq('test fact')
      expect(msg[:content_type]).to eq(:fact)
      expect(msg[:tags]).to eq(%w[vault])
      expect(msg[:source_agent]).to eq('worker-1')
    end
  end

  describe '#type' do
    it 'returns apollo_ingest' do
      expect(message.type).to eq('apollo_ingest')
    end
  end
end
