# frozen_string_literal: true

require 'spec_helper'

unless defined?(Legion::Extensions::Actors::Subscription)
  module Legion
    module Extensions
      module Actors
        class Subscription; end # rubocop:disable Lint/EmptyClass
      end
    end
  end
end
$LOADED_FEATURES << 'legion/extensions/actors/subscription' unless $LOADED_FEATURES.include?('legion/extensions/actors/subscription')

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

require 'legion/extensions/apollo/helpers/embedding'
require 'legion/extensions/apollo/helpers/capability'
require 'legion/extensions/apollo/transport/exchanges/apollo'
require 'legion/extensions/apollo/transport/messages/writeback'
require 'legion/extensions/apollo/actors/writeback_vectorize'

RSpec.describe Legion::Extensions::Apollo::Actor::WritebackVectorize do
  subject(:actor) { described_class.new }

  describe '#runner_function' do
    it 'returns handle_vectorize' do
      expect(actor.runner_function).to eq('handle_vectorize')
    end
  end

  describe '#handle_vectorize' do
    let(:payload) { { content: 'test content', content_type: 'observation', tags: %w[test] } }

    before do
      allow(Legion::Extensions::Apollo::Helpers::Embedding).to receive(:generate).and_return([0.1] * 1024)
      allow(Legion::Extensions::Apollo::Helpers::Capability).to receive(:can_write?).and_return(false)
    end

    it 'generates embedding and re-publishes when cannot write' do
      msg = instance_double(Legion::Extensions::Apollo::Transport::Messages::Writeback)
      allow(Legion::Extensions::Apollo::Transport::Messages::Writeback).to receive(:new).and_return(msg)
      allow(msg).to receive(:publish)

      result = actor.handle_vectorize(payload)
      expect(result[:success]).to be true
      expect(result[:action]).to eq(:vectorized)
      expect(msg).to have_received(:publish)
    end

    it 'writes directly when can_write? is true' do
      allow(Legion::Extensions::Apollo::Helpers::Capability).to receive(:can_write?).and_return(true)
      allow(Legion::Extensions::Apollo::Runners::Knowledge).to receive(:handle_ingest).and_return({ success: true })

      result = actor.handle_vectorize(payload)
      expect(result[:success]).to be true
      expect(Legion::Extensions::Apollo::Runners::Knowledge).to have_received(:handle_ingest)
    end

    it 'returns error hash on failure' do
      allow(Legion::Extensions::Apollo::Helpers::Embedding).to receive(:generate).and_raise(RuntimeError, 'boom')

      result = actor.handle_vectorize(payload)
      expect(result[:success]).to be false
      expect(result[:error]).to eq('boom')
    end
  end
end
