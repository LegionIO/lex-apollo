# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/runners/query_response'

RSpec.describe Legion::Extensions::Apollo::Runners::QueryResponse do
  let(:exchange) { double('default exchange') }
  let(:channel) { double('channel', default_exchange: exchange, using_publisher_confirmations?: true, wait_for_confirms: true) }
  let(:reply_queue) { double('reply queue', name: 'apollo-reply') }
  let(:replies) { [] }
  let(:dataset) { double('entries') }
  let(:database) { double('database', database_type: :postgres) }
  let(:entry_model) { double('ApolloEntry', db: database) }
  let(:entry) do
    { id: 'entry-1', content: 'A shared fact', content_type: 'fact', confidence: 0.8,
      tags: ['ruby'], source_agent: 'worker', depth: 0, activation: 1.0 }
  end

  before do
    hide_const('Legion::Data::Model::Apollo') if defined?(Legion::Data::Model::Apollo)
    hide_const('Legion::Identity::Process') if defined?(Legion::Identity::Process)
    stub_const('Legion::Data::Model::ApolloEntry', entry_model)
    allow(entry_model).to receive(:exclude).and_return(dataset)
    allow(dataset).to receive_messages(where: dataset, order: dataset, limit: dataset, all: [entry])
    allow(database).to receive(:fetch).and_return(dataset)
    allow(Legion::Transport::Connection).to receive(:channel).and_return(channel)
    allow(exchange).to receive(:on_return) { |&handler| @return_handler = handler }
    allow(exchange).to receive(:publish) do |payload, **properties|
      if properties[:routing_key].start_with?('missing-')
        @return_handler.call(nil, Struct.new(:message_id).new(properties[:message_id]), payload)
      else
        replies << { properties: properties, result: Legion::JSON.load(payload) }
      end
    end
  end

  it 'publishes the actual browse result with the AMQP correlation on the default exchange' do
    result = described_class.handle_request(query: '', reply_to: reply_queue.name, correlation_id: 'query-123')

    expect(result).to include(success: true, mode: :browse, entries: [include(id: 'entry-1')])
    expect(replies.one?).to be true
    expect(replies.first[:result]).to eq(Legion::JSON.load(Legion::JSON.dump(result)))
    expect(replies.first[:properties]).to include(routing_key: 'apollo-reply', correlation_id: 'query-123', content_type: 'application/json')
  end

  it 'uses empty-query retrieval semantics instead of returning browse entries' do
    described_class.handle_request(action: 'retrieve', query: '', reply_to: reply_queue.name)

    expect(replies.first[:result]).to eq(success: true, entries: [], count: 0)
  end

  it 'executes traversal and publishes graph depth and activation' do
    described_class.handle_request(action: 'traverse', entry_id: 'entry-1', reply_to: reply_queue.name)

    expect(replies.first[:result]).to include(success: true, entries: [include(id: 'entry-1', depth: 0, activation: 1.0)])
  end

  it 'keeps requests without a reply destination fire-and-forget' do
    expect(exchange).not_to receive(:publish)

    expect(described_class.handle_request(action: 'retrieve', query: '')).to eq(success: true, entries: [], count: 0)
  end

  it 'publishes a structured error instead of dispatching an unsupported action' do
    described_class.handle_request(action: 'delete_all', query: '', reply_to: reply_queue.name)

    expect(replies.first[:result]).to eq(success: false, error: 'invalid_action')
  end

  it 'publishes a structured error when a query body is missing' do
    described_class.handle_request(action: 'query', reply_to: reply_queue.name)

    expect(replies.first[:result]).to include(success: false, error: 'invalid_request')
  end

  it 'rejects nonpositive and malformed traversal identities rather than executing a graph lookup' do
    expect(database).not_to receive(:fetch)

    [0, -1, nil, '', [], {}, 1.5, true].each do |entry_id|
      result = described_class.handle_request(action: 'traverse', entry_id: entry_id, reply_to: reply_queue.name)

      expect(result).to include(success: false, error: :invalid_request)
      expect(replies.last[:result]).to include(success: false, error: 'invalid_request')
    end
  end

  context 'with native SQLite entry identities' do
    let(:sqlite_database) { Sequel.sqlite }

    before do
      sqlite_database.create_table(:apollo_entries) do
        primary_key :id
        String :content
        String :content_type
        Float :confidence
        String :tags
        String :source_agent
        String :status
        String :access_scope
      end
      sqlite_database.create_table(:apollo_relations) do
        primary_key :id
        Integer :from_entry_id
        Integer :to_entry_id
        String :relation_type
        Float :weight
      end
      sqlite_database[:apollo_entries].insert(id: 1, content: 'SQLite root', content_type: 'fact',
                                              confidence: 0.8, tags: '[]', source_agent: 'worker',
                                              status: 'confirmed', access_scope: 'global')
      allow(entry_model).to receive(:db).and_return(sqlite_database)
    end

    after { sqlite_database.disconnect }

    it 'traverses a positive integer and preserves its native type in the reply' do
      result = described_class.handle_request(action: 'traverse', entry_id: 1, reply_to: reply_queue.name)

      expect(result).to include(success: true, entries: [include(id: 1, content: 'SQLite root', depth: 0, activation: 1.0)])
      expect(replies.first[:result]).to include(success: true, entries: [include(id: 1)])
    end

    it 'returns an empty successful graph for a valid identity that is not present' do
      described_class.handle_request(action: 'traverse', entry_id: 2, reply_to: reply_queue.name)

      expect(replies.first[:result]).to eq(success: true, entries: [], count: 0)
    end
  end

  it 'raises when the broker cannot route the reply instead of acknowledging success' do
    expect do
      described_class.handle_request(action: 'retrieve', query: '', reply_to: "missing-#{SecureRandom.uuid}")
    end.to raise_error(IOError, /reply publication failed/)
  end

  it 'propagates publication exceptions to the subscription retry boundary' do
    allow(exchange).to receive(:publish).and_raise(IOError, 'connection lost')

    expect do
      described_class.handle_request(action: 'retrieve', query: '', reply_to: reply_queue.name)
    end.to raise_error(IOError, 'connection lost')
  end

  it 'raises on a negative publisher confirmation so the request can retry' do
    allow(channel).to receive(:wait_for_confirms).and_return(false)

    expect do
      described_class.handle_request(action: 'retrieve', query: '', reply_to: reply_queue.name)
    end.to raise_error(IOError, /reply publication failed/)
  end

  it 'retires an ambiguously timed-out channel before propagating the failure' do
    allow(channel).to receive(:wait_for_confirms).and_raise(Timeout::Error)
    allow(channel).to receive(:open?).and_return(true)
    expect(channel).to receive(:close)

    expect do
      described_class.handle_request(action: 'retrieve', query: '', reply_to: reply_queue.name)
    end.to raise_error(Timeout::Error)
  end
end
