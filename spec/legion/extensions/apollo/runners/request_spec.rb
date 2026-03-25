# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/helpers/confidence'
require 'legion/extensions/apollo/helpers/similarity'
require 'legion/extensions/apollo/helpers/graph_query'
require 'legion/extensions/apollo/runners/knowledge'
require 'legion/extensions/apollo/runners/request'

RSpec.describe Legion::Extensions::Apollo::Runners::Request do
  before do
    # Clear cached knowledge_host between examples
    described_class.instance_variable_set(:@knowledge_host, nil)

    embeddings_mod = Module.new do
      def self.generate(*, **)
        { vector: Array.new(1024, 0.0), model: 'test', provider: :ollama, dimensions: 1024, tokens: 0 }
      end
    end
    stub_const('Legion::LLM::Embeddings', embeddings_mod)
  end

  describe '.data_required?' do
    it 'returns false' do
      expect(described_class.data_required?).to be false
    end
  end

  describe '.query' do
    context 'when local service is available' do
      let(:mock_entry_class) { double('ApolloEntry') }
      let(:mock_access_log_class) { double('ApolloAccessLog') }
      let(:mock_db) { double('db') }
      let(:sample_entries) do
        [{ id: 'uuid-1', content: 'test', content_type: 'fact',
           confidence: 0.8, distance: 0.15, tags: ['ruby'], source_agent: 'agent-1' }]
      end

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
        stub_const('Legion::Data::Model::ApolloAccessLog', mock_access_log_class)
        allow(Legion::LLM::Embeddings).to receive(:generate)
          .and_return({ vector: Array.new(1024, 0.0), model: 'test', provider: :ollama, dimensions: 1024, tokens: 0 })
        allow(mock_entry_class).to receive(:db).and_return(mock_db)
        allow(mock_db).to receive(:fetch).and_return(double(all: sample_entries))
        allow(mock_entry_class).to receive(:where).and_return(double(update: true))
        allow(mock_access_log_class).to receive(:create)
      end

      it 'delegates to Knowledge.handle_query' do
        result = described_class.query(text: 'test query')
        expect(result[:success]).to be true
        expect(result[:entries]).to be_an(Array)
      end
    end

    context 'when only transport is available' do
      let(:mock_transport) do
        Module.new do
          def self.connected?
            true
          end

          def self.respond_to?(method, *args)
            method == :connected? || super
          end
        end
      end
      let(:mock_message) { double('message', publish: true) }

      before do
        hide_const('Legion::Data::Model::ApolloEntry') if defined?(Legion::Data::Model::ApolloEntry)
        stub_const('Legion::Transport', mock_transport)
        stub_const('Legion::Extensions::Apollo::Transport::Messages::Query',
                   double('QueryMsg', new: mock_message))
      end

      it 'publishes via transport' do
        result = described_class.query(text: 'test query')
        expect(result[:success]).to be true
        expect(result[:dispatched]).to eq(:transport)
      end
    end

    context 'when neither local nor transport is available' do
      before do
        hide_const('Legion::Data::Model::ApolloEntry') if defined?(Legion::Data::Model::ApolloEntry)
        hide_const('Legion::Transport') if defined?(Legion::Transport)
      end

      it 'returns no_path_available error' do
        result = described_class.query(text: 'test query')
        expect(result[:success]).to be false
        expect(result[:error]).to eq(:no_path_available)
      end
    end
  end

  describe '.retrieve' do
    context 'when local service is available' do
      let(:mock_entry_class) { double('ApolloEntry') }
      let(:mock_db) { double('db') }

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
        allow(Legion::LLM::Embeddings).to receive(:generate)
          .and_return({ vector: Array.new(1024, 0.0), model: 'test', provider: :ollama, dimensions: 1024, tokens: 0 })
        allow(mock_entry_class).to receive(:db).and_return(mock_db)
        allow(mock_db).to receive(:fetch).and_return(double(all: []))
        allow(mock_entry_class).to receive(:where).and_return(double(update: true))
      end

      it 'delegates to Knowledge.retrieve_relevant' do
        result = described_class.retrieve(text: 'test query')
        expect(result[:success]).to be true
        expect(result[:entries]).to eq([])
      end
    end

    context 'when neither path is available' do
      before do
        hide_const('Legion::Data::Model::ApolloEntry') if defined?(Legion::Data::Model::ApolloEntry)
        hide_const('Legion::Transport') if defined?(Legion::Transport)
      end

      it 'returns no_path_available' do
        result = described_class.retrieve(text: 'test')
        expect(result[:success]).to be false
        expect(result[:error]).to eq(:no_path_available)
      end
    end
  end

  describe '.ingest' do
    context 'when local service is available' do
      let(:mock_entry_class) { double('ApolloEntry') }
      let(:mock_expertise_class) { double('ApolloExpertise') }
      let(:mock_access_log_class) { double('ApolloAccessLog') }
      let(:mock_entry) { double('entry', id: 'uuid-123', embedding: nil) }

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
        stub_const('Legion::Data::Model::ApolloExpertise', mock_expertise_class)
        stub_const('Legion::Data::Model::ApolloAccessLog', mock_access_log_class)
        allow(Legion::LLM::Embeddings).to receive(:generate)
          .and_return({ vector: Array.new(1024, 0.0), model: 'test', provider: :ollama, dimensions: 1024, tokens: 0 })
        allow(mock_entry_class).to receive(:where).and_return(double(exclude: double(limit: double(each: nil), first: nil)))
        allow(mock_entry_class).to receive(:exclude)
          .and_return(double(exclude: double(limit: double(all: []))))
        allow(mock_entry_class).to receive(:db).and_return(double(fetch: double(all: [])))
        allow(mock_entry_class).to receive(:create).and_return(mock_entry)
        allow(mock_expertise_class).to receive(:where).and_return(double(first: nil))
        allow(mock_expertise_class).to receive(:create)
        allow(mock_access_log_class).to receive(:create)
      end

      it 'delegates to Knowledge.handle_ingest' do
        result = described_class.ingest(content: 'test fact', content_type: 'fact', source_agent: 'agent-1')
        expect(result[:success]).to be true
        expect(result[:entry_id]).to eq('uuid-123')
      end
    end

    context 'when neither path is available' do
      before do
        hide_const('Legion::Data::Model::ApolloEntry') if defined?(Legion::Data::Model::ApolloEntry)
        hide_const('Legion::Transport') if defined?(Legion::Transport)
      end

      it 'returns no_path_available' do
        result = described_class.ingest(content: 'test', content_type: 'fact')
        expect(result[:success]).to be false
        expect(result[:error]).to eq(:no_path_available)
      end
    end
  end

  describe '.traverse' do
    context 'when neither path is available' do
      before do
        hide_const('Legion::Data::Model::ApolloEntry') if defined?(Legion::Data::Model::ApolloEntry)
        hide_const('Legion::Transport') if defined?(Legion::Transport)
      end

      it 'returns no_path_available' do
        result = described_class.traverse(entry_id: 'uuid-1')
        expect(result[:success]).to be false
        expect(result[:error]).to eq(:no_path_available)
      end
    end
  end
end
