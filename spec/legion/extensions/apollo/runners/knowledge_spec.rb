# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/helpers/confidence'
require 'legion/extensions/apollo/helpers/similarity'
require 'legion/extensions/apollo/helpers/embedding'
require 'legion/extensions/apollo/helpers/graph_query'
require 'legion/extensions/apollo/runners/knowledge'

RSpec.describe Legion::Extensions::Apollo::Runners::Knowledge do
  let(:runner) do
    obj = Object.new
    obj.extend(described_class)
    obj
  end

  describe '#store_knowledge' do
    it 'returns a message payload hash' do
      result = runner.store_knowledge(
        content:      'Vault namespace ash1234 uses PKI',
        content_type: :fact,
        tags:         %w[vault pki]
      )
      expect(result).to be_a(Hash)
      expect(result[:action]).to eq(:store)
      expect(result[:content]).to eq('Vault namespace ash1234 uses PKI')
      expect(result[:content_type]).to eq(:fact)
      expect(result[:tags]).to eq(%w[vault pki])
    end

    it 'includes source_agent when provided' do
      result = runner.store_knowledge(
        content: 'test', content_type: :fact, source_agent: 'worker-1'
      )
      expect(result[:source_agent]).to eq('worker-1')
    end

    it 'rejects invalid content_type' do
      expect do
        runner.store_knowledge(content: 'test', content_type: :invalid)
      end.to raise_error(ArgumentError, /content_type/)
    end
  end

  describe '#query_knowledge' do
    it 'returns a query payload hash' do
      result = runner.query_knowledge(query: 'PKI configuration')
      expect(result[:action]).to eq(:query)
      expect(result[:query]).to eq('PKI configuration')
      expect(result[:limit]).to eq(10)
      expect(result[:min_confidence]).to eq(0.3)
    end

    it 'accepts custom limit and filters' do
      result = runner.query_knowledge(
        query: 'vault', limit: 5, min_confidence: 0.5,
        status: [:confirmed], tags: %w[vault]
      )
      expect(result[:limit]).to eq(5)
      expect(result[:min_confidence]).to eq(0.5)
      expect(result[:status]).to eq([:confirmed])
      expect(result[:tags]).to eq(%w[vault])
    end
  end

  describe '#related_entries' do
    it 'returns a traversal payload hash' do
      result = runner.related_entries(entry_id: 'uuid-123')
      expect(result[:action]).to eq(:traverse)
      expect(result[:entry_id]).to eq('uuid-123')
      expect(result[:depth]).to eq(2)
    end

    it 'accepts relation_types filter' do
      result = runner.related_entries(
        entry_id: 'uuid-123', relation_types: %w[causes depends_on], depth: 3
      )
      expect(result[:relation_types]).to eq(%w[causes depends_on])
      expect(result[:depth]).to eq(3)
    end
  end

  describe '#deprecate_entry' do
    it 'returns a deprecate payload' do
      result = runner.deprecate_entry(entry_id: 'uuid-123', reason: 'outdated')
      expect(result[:action]).to eq(:deprecate)
      expect(result[:entry_id]).to eq('uuid-123')
      expect(result[:reason]).to eq('outdated')
    end
  end

  describe '#handle_ingest' do
    let(:host) { Object.new.extend(described_class) }

    context 'when Apollo data is not available' do
      before { hide_const('Legion::Data::Model::ApolloEntry') if defined?(Legion::Data::Model::ApolloEntry) }

      it 'returns a structured error' do
        result = host.handle_ingest(content: 'test', content_type: 'fact')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('apollo_data_not_available')
      end
    end

    context 'when Apollo data is available' do
      let(:mock_entry_class) { double('ApolloEntry') }
      let(:mock_relation_class) { double('ApolloRelation') }
      let(:mock_expertise_class) { double('ApolloExpertise') }
      let(:mock_access_log_class) { double('ApolloAccessLog') }
      let(:mock_entry) { double('entry', id: 'uuid-123', embedding: nil) }
      let(:empty_dataset) { double('dataset', each: nil) }

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
        stub_const('Legion::Data::Model::ApolloRelation', mock_relation_class)
        stub_const('Legion::Data::Model::ApolloExpertise', mock_expertise_class)
        stub_const('Legion::Data::Model::ApolloAccessLog', mock_access_log_class)
        allow(Legion::Extensions::Apollo::Helpers::Embedding).to receive(:generate)
          .and_return(Array.new(1536, 0.0))

        allow(mock_entry_class).to receive(:where).and_return(double(exclude: double(limit: empty_dataset)))
        allow(mock_entry_class).to receive(:exclude)
          .and_return(double(exclude: double(limit: double(all: []))))
        allow(mock_entry_class).to receive(:create).and_return(mock_entry)
        allow(mock_expertise_class).to receive(:where).and_return(double(first: nil))
        allow(mock_expertise_class).to receive(:create)
        allow(mock_access_log_class).to receive(:create)
      end

      it 'creates a new candidate entry when novel' do
        result = host.handle_ingest(content: 'Ruby is great', content_type: 'fact',
                                    tags: ['ruby'], source_agent: 'agent-1')
        expect(result[:success]).to be true
        expect(result[:status]).to eq('candidate')
        expect(result[:corroborated]).to be false
      end

      it 'creates expertise record for source agent' do
        expect(mock_expertise_class).to receive(:create).with(
          hash_including(agent_id: 'agent-1', domain: 'ruby')
        )
        host.handle_ingest(content: 'Ruby is great', content_type: 'fact',
                           tags: ['ruby'], source_agent: 'agent-1')
      end

      it 'logs access' do
        expect(mock_access_log_class).to receive(:create).with(
          hash_including(agent_id: 'agent-1', action: 'ingest')
        )
        host.handle_ingest(content: 'Ruby is great', content_type: 'fact',
                           tags: ['ruby'], source_agent: 'agent-1')
      end

      it 'defaults domain to general when no tags' do
        expect(mock_expertise_class).to receive(:create).with(
          hash_including(domain: 'general')
        )
        host.handle_ingest(content: 'test', content_type: 'fact', source_agent: 'agent-1')
      end
    end

    context 'when Sequel raises an error' do
      before do
        stub_const('Legion::Data::Model::ApolloEntry', Class.new)
        allow(Legion::Extensions::Apollo::Helpers::Embedding).to receive(:generate)
          .and_return(Array.new(1536, 0.0))
        allow(Legion::Data::Model::ApolloEntry).to receive(:where)
          .and_raise(Sequel::Error, 'connection lost')
      end

      it 'returns a structured error' do
        result = host.handle_ingest(content: 'test', content_type: 'fact', source_agent: 'a')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('connection lost')
      end
    end
  end

  describe '#handle_query' do
    let(:host) { Object.new.extend(described_class) }

    context 'when Apollo data is not available' do
      before { hide_const('Legion::Data::Model::ApolloEntry') if defined?(Legion::Data::Model::ApolloEntry) }

      it 'returns a structured error' do
        result = host.handle_query(query: 'test')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('apollo_data_not_available')
      end
    end

    context 'when Apollo data is available' do
      let(:mock_entry_class) { double('ApolloEntry') }
      let(:mock_access_log_class) { double('ApolloAccessLog') }
      let(:mock_db) { double('db') }
      let(:sample_entries) do
        [{ id: 'uuid-1', content: 'Ruby is interpreted', content_type: 'fact',
           confidence: 0.8, distance: 0.15, tags: ['ruby'], source_agent: 'agent-1',
           access_count: 3 }]
      end

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
        stub_const('Legion::Data::Model::ApolloAccessLog', mock_access_log_class)
        allow(Legion::Extensions::Apollo::Helpers::Embedding).to receive(:generate)
          .and_return(Array.new(1536, 0.0))
        allow(mock_entry_class).to receive(:db).and_return(mock_db)
        allow(mock_db).to receive(:fetch).and_return(double(all: sample_entries))
        allow(mock_entry_class).to receive(:where).and_return(double(update: true))
        allow(mock_access_log_class).to receive(:create)
      end

      it 'returns matching entries' do
        result = host.handle_query(query: 'Ruby', agent_id: 'agent-2')
        expect(result[:success]).to be true
        expect(result[:count]).to eq(1)
        expect(result[:entries].first[:content]).to eq('Ruby is interpreted')
      end

      it 'boosts access count on matched entries' do
        expect(mock_entry_class).to receive(:where).with(id: 'uuid-1')
                                                   .and_return(double(update: true))
        host.handle_query(query: 'Ruby', agent_id: 'agent-2')
      end

      it 'logs query access' do
        expect(mock_access_log_class).to receive(:create).with(
          hash_including(agent_id: 'agent-2', action: 'query')
        )
        host.handle_query(query: 'Ruby', agent_id: 'agent-2')
      end
    end

    context 'when no results found' do
      let(:mock_entry_class) { double('ApolloEntry') }
      let(:mock_db) { double('db') }

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
        allow(Legion::Extensions::Apollo::Helpers::Embedding).to receive(:generate)
          .and_return(Array.new(1536, 0.0))
        allow(mock_entry_class).to receive(:db).and_return(mock_db)
        allow(mock_db).to receive(:fetch).and_return(double(all: []))
      end

      it 'returns empty entries array' do
        result = host.handle_query(query: 'nonexistent')
        expect(result[:success]).to be true
        expect(result[:entries]).to eq([])
        expect(result[:count]).to eq(0)
      end
    end
  end

  describe '#retrieve_relevant' do
    let(:host) { Object.new.extend(described_class) }

    it 'returns skipped when skip is true' do
      result = host.retrieve_relevant(skip: true)
      expect(result[:status]).to eq(:skipped)
    end

    context 'when Apollo data is not available' do
      before { hide_const('Legion::Data::Model::ApolloEntry') if defined?(Legion::Data::Model::ApolloEntry) }

      it 'returns a structured error' do
        result = host.retrieve_relevant(query: 'test')
        expect(result[:success]).to be false
      end
    end

    it 'returns empty when query is nil' do
      stub_const('Legion::Data::Model::ApolloEntry', Class.new)
      result = host.retrieve_relevant(query: nil)
      expect(result[:success]).to be true
      expect(result[:entries]).to eq([])
    end

    it 'returns empty when query is blank' do
      stub_const('Legion::Data::Model::ApolloEntry', Class.new)
      result = host.retrieve_relevant(query: '  ')
      expect(result[:success]).to be true
      expect(result[:entries]).to eq([])
    end

    context 'with valid query and data available' do
      let(:mock_entry_class) { double('ApolloEntry') }
      let(:mock_db) { double('db') }
      let(:sample_entries) do
        [{ id: 'uuid-1', content: 'fact', content_type: 'fact',
           confidence: 0.7, distance: 0.2, tags: ['ruby'], source_agent: 'agent-1' }]
      end

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
        allow(Legion::Extensions::Apollo::Helpers::Embedding).to receive(:generate)
          .and_return(Array.new(1536, 0.0))
        allow(mock_entry_class).to receive(:db).and_return(mock_db)
        allow(mock_db).to receive(:fetch).and_return(double(all: sample_entries))
        allow(mock_entry_class).to receive(:where).and_return(double(update: true))
      end

      it 'returns entries without access logging' do
        result = host.retrieve_relevant(query: 'Ruby facts')
        expect(result[:success]).to be true
        expect(result[:count]).to eq(1)
      end
    end
  end

  describe '#redistribute_knowledge' do
    let(:host) { Object.new.extend(described_class) }

    context 'when Apollo data is not available' do
      before { hide_const('Legion::Data::Model::ApolloEntry') if defined?(Legion::Data::Model::ApolloEntry) }

      it 'returns a structured error' do
        result = host.redistribute_knowledge(agent_id: 'agent-x')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('apollo_data_not_available')
      end
    end

    context 'when the departing agent has no confirmed entries' do
      let(:mock_entry_class) { double('ApolloEntry') }

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
        chain = double('chain')
        allow(mock_entry_class).to receive(:where).and_return(chain)
        allow(chain).to receive(:where).and_return(double(all: []))
      end

      it 'returns success with zero redistributed' do
        result = host.redistribute_knowledge(agent_id: 'departed-1')
        expect(result[:success]).to be true
        expect(result[:redistributed]).to eq(0)
      end
    end

    context 'when the departing agent has confirmed entries' do
      let(:mock_entry_class) { double('ApolloEntry') }
      let(:mock_entry) do
        double('entry', content: 'Ruby is fast', content_type: 'fact',
                        confidence: 0.8, tags: ['ruby'])
      end

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
        chain = double('chain')
        allow(mock_entry_class).to receive(:where).and_return(chain)
        allow(chain).to receive(:where).and_return(double(all: [mock_entry]))
      end

      it 'returns the count of redistributed entries' do
        result = host.redistribute_knowledge(agent_id: 'departed-2')
        expect(result[:success]).to be true
        expect(result[:redistributed]).to eq(1)
        expect(result[:agent_id]).to eq('departed-2')
      end

      it 'stores into trace shared_store when Memory::Trace is available' do
        mock_store = double('store')
        mock_trace_helpers = Module.new do
          def self.new_trace(type:, content_payload: nil, **kwargs) # rubocop:disable Lint/UnusedMethodArgument
            { trace_id: 'trace-abc', trace_type: type, strength: kwargs[:strength] || 0.5 }
          end
        end
        stub_const('Legion::Extensions::Agentic::Memory::Trace', Module.new)
        stub_const('Legion::Extensions::Agentic::Memory::Trace::Helpers::Trace', mock_trace_helpers)
        allow(Legion::Extensions::Agentic::Memory::Trace).to receive(:shared_store).and_return(mock_store)
        allow(mock_store).to receive(:store)

        result = host.redistribute_knowledge(agent_id: 'departed-3')
        expect(result[:redistributed]).to eq(1)
        expect(mock_store).to have_received(:store).once
      end
    end

    context 'when Sequel raises an error' do
      before do
        stub_const('Legion::Data::Model::ApolloEntry', Class.new)
        allow(Legion::Data::Model::ApolloEntry).to receive(:where)
          .and_raise(Sequel::Error, 'db error')
      end

      it 'returns a structured error' do
        result = host.redistribute_knowledge(agent_id: 'agent-x')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('db error')
      end
    end
  end
end
