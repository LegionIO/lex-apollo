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

      let(:mock_db) { double('db') }

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
        stub_const('Legion::Data::Model::ApolloRelation', mock_relation_class)
        stub_const('Legion::Data::Model::ApolloExpertise', mock_expertise_class)
        stub_const('Legion::Data::Model::ApolloAccessLog', mock_access_log_class)
        allow(Legion::Extensions::Apollo::Helpers::Embedding).to receive(:generate)
          .and_return(Array.new(1536, 0.0))

        allow(mock_entry_class).to receive(:where).and_return(double(exclude: double(limit: empty_dataset)))
        allow(mock_entry_class).to receive(:db).and_return(mock_db)
        allow(mock_db).to receive(:fetch).and_return(double(all: []))
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

      it 'passes source_channel to create' do
        expect(mock_entry_class).to receive(:create).with(
          hash_including(source_channel: 'slack-alerts')
        ).and_return(mock_entry)
        host.handle_ingest(content: 'test', content_type: 'fact',
                           source_agent: 'agent-1', source_channel: 'slack-alerts')
      end

      it 'passes knowledge_domain to create from explicit param' do
        expect(mock_entry_class).to receive(:create).with(
          hash_including(knowledge_domain: 'clinical')
        ).and_return(mock_entry)
        host.handle_ingest(content: 'test', content_type: 'fact',
                           source_agent: 'agent-1', knowledge_domain: 'clinical')
      end

      it 'defaults knowledge_domain to first tag' do
        expect(mock_entry_class).to receive(:create).with(
          hash_including(knowledge_domain: 'cardiology')
        ).and_return(mock_entry)
        host.handle_ingest(content: 'test', content_type: 'fact',
                           tags: %w[cardiology treatment], source_agent: 'agent-1')
      end

      it 'defaults knowledge_domain to general when no tags and no explicit domain' do
        expect(mock_entry_class).to receive(:create).with(
          hash_including(knowledge_domain: 'general')
        ).and_return(mock_entry)
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

      it 'passes domain to graph query builder' do
        expect(Legion::Extensions::Apollo::Helpers::GraphQuery).to receive(:build_semantic_search_sql).with(
          hash_including(domain: 'clinical')
        ).and_call_original
        host.retrieve_relevant(query: 'treatment', domain: 'clinical')
      end
    end
  end

  describe '#handle_traverse' do
    let(:host) { Object.new.extend(described_class) }

    context 'when Apollo data is not available' do
      before { hide_const('Legion::Data::Model::ApolloEntry') if defined?(Legion::Data::Model::ApolloEntry) }

      it 'returns a structured error' do
        result = host.handle_traverse(entry_id: 'uuid-123')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('apollo_data_not_available')
      end
    end

    context 'when Apollo data is available' do
      let(:mock_entry_class) { double('ApolloEntry') }
      let(:mock_access_log_class) { double('ApolloAccessLog') }
      let(:mock_db) { double('db') }
      let(:traversal_results) do
        [{ id: 'uuid-1', content: 'root', content_type: 'fact',
           confidence: 0.8, tags: ['ruby'], source_agent: 'agent-1',
           depth: 0, activation: 1.0 },
         { id: 'uuid-2', content: 'related', content_type: 'concept',
           confidence: 0.6, tags: ['ruby'], source_agent: 'agent-2',
           depth: 1, activation: 0.48 }]
      end

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
        stub_const('Legion::Data::Model::ApolloAccessLog', mock_access_log_class)
        allow(mock_entry_class).to receive(:db).and_return(mock_db)
        allow(mock_db).to receive(:fetch).and_return(double(all: traversal_results))
        allow(mock_access_log_class).to receive(:create)
      end

      it 'executes traversal SQL and returns formatted entries' do
        result = host.handle_traverse(entry_id: 'uuid-1', agent_id: 'agent-x')
        expect(result[:success]).to be true
        expect(result[:count]).to eq(2)
        expect(result[:entries].first[:depth]).to eq(0)
        expect(result[:entries].last[:activation]).to eq(0.48)
      end

      it 'logs access for known agents' do
        expect(mock_access_log_class).to receive(:create).with(
          hash_including(agent_id: 'agent-x', action: 'query')
        )
        host.handle_traverse(entry_id: 'uuid-1', agent_id: 'agent-x')
      end

      it 'skips access logging for unknown agents' do
        expect(mock_access_log_class).not_to receive(:create)
        host.handle_traverse(entry_id: 'uuid-1')
      end

      it 'filters invalid relation_types' do
        expect(Legion::Extensions::Apollo::Helpers::GraphQuery).to receive(:build_traversal_sql).with(
          hash_including(relation_types: ['causes'])
        ).and_call_original
        host.handle_traverse(entry_id: 'uuid-1', relation_types: %w[causes invalid_type])
      end
    end

    context 'when Sequel raises an error' do
      before do
        stub_const('Legion::Data::Model::ApolloEntry', Class.new)
        allow(Legion::Data::Model::ApolloEntry).to receive(:db)
          .and_raise(Sequel::Error, 'connection lost')
      end

      it 'returns a structured error' do
        result = host.handle_traverse(entry_id: 'uuid-1')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('connection lost')
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

  describe '#prepare_mesh_export' do
    let(:host) { Object.new.extend(described_class) }

    context 'when Legion::Data is not available' do
      before { hide_const('Legion::Data') if defined?(Legion::Data) }

      it 'returns a structured error' do
        result = host.prepare_mesh_export(target_domain: 'clinical_care')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('apollo_data_not_available')
      end
    end

    context 'when data is available' do
      let(:mock_conn) { double('connection') }
      let(:mock_dataset) { double('dataset') }
      let(:clinical_entry) do
        { id: 'e1', content: 'treatment', content_type: 'fact',
          confidence: 0.8, knowledge_domain: 'clinical_care',
          tags: ['clinical'], source_agent: 'agent-1' }
      end
      let(:claims_entry) do
        { id: 'e2', content: 'denial', content_type: 'fact',
          confidence: 0.7, knowledge_domain: 'claims_optimization',
          tags: ['claims'], source_agent: 'agent-2' }
      end

      before do
        data_mod = Module.new do
          def self.connection; end

          def self.respond_to?(method, *args)
            method == :connection || super
          end
        end
        stub_const('Legion::Data', data_mod)
        allow(Legion::Data).to receive(:connection).and_return(mock_conn)
        allow(mock_conn).to receive(:[]).with(:apollo_entries).and_return(mock_dataset)
        allow(mock_dataset).to receive(:where).and_return(mock_dataset)
        allow(mock_dataset).to receive(:limit).and_return(mock_dataset)
      end

      it 'filters entries by domain compatibility for clinical_care' do
        allow(mock_dataset).to receive(:all).and_return([clinical_entry])
        result = host.prepare_mesh_export(target_domain: 'clinical_care')
        expect(result[:success]).to be true
        expect(result[:target_domain]).to eq('clinical_care')
      end

      it 'allows all domains when target is general' do
        allow(mock_dataset).to receive(:all).and_return([clinical_entry, claims_entry])
        result = host.prepare_mesh_export(target_domain: 'general')
        expect(result[:success]).to be true
        expect(result[:count]).to eq(2)
      end

      it 'restricts claims_optimization to only claims entries' do
        allow(mock_dataset).to receive(:all).and_return([claims_entry])
        result = host.prepare_mesh_export(target_domain: 'claims_optimization')
        expect(result[:success]).to be true
      end
    end
  end

  describe '#handle_erasure_request' do
    let(:host) { Object.new.extend(described_class) }

    context 'when Legion::Data is not available' do
      before { hide_const('Legion::Data') if defined?(Legion::Data) }

      it 'returns zero counts with error' do
        result = host.handle_erasure_request(agent_id: 'agent-dead')
        expect(result[:deleted]).to eq(0)
        expect(result[:redacted]).to eq(0)
        expect(result[:error]).to eq('apollo_data_not_available')
      end
    end

    context 'when data is available' do
      let(:mock_conn) { double('connection') }
      let(:mock_dataset) { double('dataset') }

      before do
        data_mod = Module.new do
          def self.connection; end

          def self.respond_to?(method, *args)
            method == :connection || super
          end
        end
        stub_const('Legion::Data', data_mod)
        allow(Legion::Data).to receive(:connection).and_return(mock_conn)
        allow(mock_conn).to receive(:[]).with(:apollo_entries).and_return(mock_dataset)
        allow(mock_dataset).to receive(:where).and_return(mock_dataset)
        allow(mock_dataset).to receive(:exclude).and_return(mock_dataset)
        allow(mock_dataset).to receive(:delete).and_return(3)
        allow(mock_dataset).to receive(:update).and_return(2)
      end

      it 'deletes non-confirmed entries and redacts confirmed ones' do
        result = host.handle_erasure_request(agent_id: 'agent-dead')
        expect(result[:deleted]).to eq(3)
        expect(result[:redacted]).to eq(2)
        expect(result[:agent_id]).to eq('agent-dead')
      end
    end

    context 'when Sequel raises an error' do
      before do
        data_mod = Module.new do
          def self.connection; end

          def self.respond_to?(method, *args)
            method == :connection || super
          end
        end
        stub_const('Legion::Data', data_mod)
        allow(Legion::Data).to receive(:connection).and_return(double('conn').tap do |c|
          allow(c).to receive(:[]).and_raise(Sequel::Error, 'db gone')
        end)
      end

      it 'returns zero counts with the error message' do
        result = host.handle_erasure_request(agent_id: 'agent-dead')
        expect(result[:deleted]).to eq(0)
        expect(result[:redacted]).to eq(0)
        expect(result[:error]).to eq('db gone')
      end
    end
  end
end
