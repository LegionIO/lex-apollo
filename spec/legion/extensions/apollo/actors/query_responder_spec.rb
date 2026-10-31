# frozen_string_literal: true

require 'spec_helper'

$LOADED_FEATURES << 'legion/extensions/actors/subscription' unless $LOADED_FEATURES.include?('legion/extensions/actors/subscription')
require 'legion/extensions/apollo/actors/query_responder'

RSpec.describe Legion::Extensions::Apollo::Actor::QueryResponder do
  subject(:actor) { described_class.new }

  let(:payload) { Legion::JSON.dump(action: 'retrieve', query: '') }
  let(:delivery) { { routing_key: 'legion.apollo.query' } }

  it 'preserves superclass decoding and takes reply routing from AMQP properties over body values' do
    metadata = double('properties', reply_to: 'envelope-reply', correlation_id: 'envelope-correlation')
    decoded = { action: 'retrieve', query: '', routing_key: 'legion.apollo.query', reply_to: 'body-reply', correlation_id: 'body-correlation' }
    allow_any_instance_of(described_class.superclass).to receive(:process_message).with(payload, metadata, delivery).and_return(decoded)

    expect(actor.process_message(payload, metadata, delivery)).to eq(
      action: 'retrieve', query: '', routing_key: 'legion.apollo.query', reply_to: 'envelope-reply', correlation_id: 'envelope-correlation'
    )
  end

  it 'retains payload reply metadata when a broker producer did not supply envelope properties' do
    metadata = double('properties', reply_to: nil, correlation_id: nil)
    decoded = { action: 'retrieve', query: '', reply_to: 'body-reply', correlation_id: 'body-correlation' }
    allow_any_instance_of(described_class.superclass).to receive(:process_message).and_return(decoded)

    expect(actor.process_message(payload, metadata, delivery)).to include(reply_to: 'body-reply', correlation_id: 'body-correlation')
  end

  it 'does not add reply fields to fire-and-forget requests' do
    metadata = double('properties', reply_to: nil, correlation_id: nil)
    allow_any_instance_of(described_class.superclass).to receive(:process_message).and_return(action: 'retrieve', query: '')

    request = actor.process_message(payload, metadata, delivery)
    expect(request).not_to have_key(:reply_to)
    expect(request).not_to have_key(:correlation_id)
  end

  it 'retains the RPC envelope and opaque payload when publishing a retry' do
    stub_const('Legion::Extensions::Actors::RetryPolicy::RETRY_COUNT_HEADER', 'x-retry-count')
    exchange = double('default exchange')
    queue = double('query queue', name: 'legion.apollo.query', channel: double(default_exchange: exchange))
    actor.instance_variable_set(:@queue, queue)
    metadata = double('properties', reply_to: 'reply-queue', correlation_id: 'request-123',
                                   content_type: 'application/json', content_encoding: 'encrypted/cs', headers: { 'iv' => 'cipher-iv' })
    publications = []
    allow(exchange).to receive(:publish) { |body, **envelope| publications << [body, envelope] }

    actor.send(:republish_with_retry_count, delivery, metadata, 'opaque-encrypted-bytes', 1)

    expect(publications).to eq([
                                 ['opaque-encrypted-bytes', { routing_key: 'legion.apollo.query', reply_to: 'reply-queue', correlation_id: 'request-123',
                                                             content_type: 'application/json', content_encoding: 'encrypted/cs', persistent: true,
                                                             headers: { 'iv' => 'cipher-iv', 'x-retry-count' => 1 } }]
                               ])
  end
end
