# frozen_string_literal: true

require 'spec_helper'
require 'legion/crypt'
require 'open3'

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
        source_channel: 'chat', source_model: 'producer-model', content_hash: 'digest', context: { request_id: 'request' },
        embedding: [0.6, 0.8], embedding_provenance: { space_id: 'a' * 64, dimensions: 2, model: 'embed-model' }
      }
      [true, false].each do |has_embedding|
        options = base_opts.merge(metadata).merge(has_embedding: has_embedding, encrypt: false)
        message = described_class.new(**options)

        expect(Legion::JSON.load(message.encode_message)).to include(base_opts.merge(metadata))
        expect(message.publish_envelope_options(options: options)).to include(content_type: 'application/json')
      end
    end
  end

  describe '#publish' do
    let(:channel) { double('channel', using_publisher_confirmations?: false, confirm_select: true, wait_for_confirms: true, open?: true, close: true) }
    let(:exchange) { double('exchange', name: 'legion.apollo', channel: channel) }
    let(:publications) { [] }
    let(:message) { described_class.new(**base_opts, encrypt: false, correlation_id: 'request-123') }
    let(:return_state) { {} }

    before do
      allow(Legion::Extensions::Apollo::Transport::Exchanges::Apollo).to receive(:cached_instance).and_return(exchange)
      allow(exchange).to receive(:on_return) { |&callback| return_state[:callback] = callback }
      allow(exchange).to receive(:publish) { |body, **envelope| publications << [body, envelope] }
    end

    it 'reports success only after confirmed publication with the inherited JSON envelope' do
      result = message.publish
      body, envelope = publications.fetch(0)
      expect(result).to include(accepted: true, status: :accepted)
      expect(Legion::JSON.load(body)).to include(base_opts)
      expect(envelope).to include(content_type: 'application/json', content_encoding: 'identity', mandatory: true,
                                  correlation_id: 'request-123', message_id: result[:message_id])
    end

    it 'publishes ciphertext that decrypts with the emitted IV' do
      encrypted = described_class.new(**base_opts, encrypt: true)
      allow(Legion::Settings).to receive(:dig).and_call_original
      allow(Legion::Settings).to receive(:dig).with(:crypt, :cs_encrypt_ready).and_return(true)
      allow(Legion::Crypt).to receive(:cs).and_return('a' * 32)
      encrypted.publish
      body, envelope = publications.fetch(0)
      expect(envelope).to include(content_encoding: 'encrypted/cs')
      plaintext = Legion::Crypt.decrypt(body, envelope[:headers][:iv])
      expect(Legion::JSON.load(plaintext)).to include(base_opts)
    end

    it 'raises on mandatory returns even when the broker confirms receipt' do
      allow(exchange).to receive(:publish) do |_body, **envelope|
        return_info = double(reply_code: 312, reply_text: 'NO_ROUTE')
        return_state[:callback].call(return_info, double(headers: envelope[:headers]), nil)
      end
      expect { message.publish }.to raise_error(IOError)
    end

    it 'does not mistake another publication return for this message' do
      allow(exchange).to receive(:publish) do
        return_state[:callback].call(nil, double(headers: {}), nil)
      end
      expect(message.publish[:accepted]).to be true
    end

    it 'rejects negative and absent broker confirms' do
      [false, nil].each do |confirmation|
        allow(channel).to receive(:wait_for_confirms).and_return(confirmation)
        expect { message.publish }.to raise_error(IOError)
      end
    end

    it 'bounds confirm waiting and closes the timed-out channel before retry' do
      closed = false
      allow(channel).to receive(:wait_for_confirms) { sleep 1 }
      allow(channel).to receive(:close) { closed = true }
      expect { message.publish({ publish_confirm_timeout_ms: 10 }) }.to raise_error(Timeout::Error)
      expect(closed).to be true
    end

    it 'propagates a network failure rather than reporting queued or spooled success' do
      allow(exchange).to receive(:publish).and_raise(IOError, 'disconnected')
      expect { message.publish }.to raise_error(IOError, 'disconnected')
    end
  end

  it 'delivers confirmed writeback through real in-process transport without a database' do
    script = <<~'RUBY'
      require 'bundler/setup'
      require 'legion/transport'
      require 'legion/extensions/apollo/transport/exchanges/apollo'
      require 'legion/extensions/apollo/transport/messages/writeback'
      Legion::Transport::Connection.setup
      channel = Legion::Transport::Connection.session.create_channel
      queue = Legion::Transport::CONNECTOR::Queue.new(channel, 'writeback-smoke')
      queue.bind('legion.apollo', routing_key: 'legion.apollo.writeback.store')
      deliveries = []
      queue.subscribe(manual_ack: false) do |_delivery, _properties, payload|
        deliveries << Legion::JSON.load(payload)
      end
      result = Legion::Extensions::Apollo::Transport::Messages::Writeback.new(
        content: 'local fact', content_type: 'fact', has_embedding: true,
        embedding: [0.6, 0.8], identity_principal_id: 41, encrypt: false
      ).publish
      Legion::Transport::Connection.shutdown
      puts "APOLLO_RESULT=#{Legion::JSON.dump({ result: result, deliveries: deliveries })}"
    RUBY
    stdout, stderr, status = Open3.capture3(
      { 'LEGION_MODE' => 'lite' }, RbConfig.ruby, '-Ilib', '-e', script,
      chdir: File.expand_path('../../../../../..', __dir__)
    )
    line = stdout.lines.find { |output| output.start_with?('APOLLO_RESULT=') }
    raise "Writeback process failed: #{stderr}\n#{stdout}" unless status.success? && line

    state = Legion::JSON.load(line.delete_prefix('APOLLO_RESULT='))
    expect(state[:result]).to include(accepted: true, status: 'accepted')
    expect(state[:deliveries]).to contain_exactly(
      include(content: 'local fact', content_type: 'fact', embedding: [0.6, 0.8], identity_principal_id: 41)
    )
  end

  describe '#validate' do
    it 'raises on missing content' do
      expect { described_class.new(**base_opts, content: nil) }.to raise_error(TypeError)
    end
  end
end
