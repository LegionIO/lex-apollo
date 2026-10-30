# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'
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
      def self.generate(task: :document, **)
        ApolloSpecEmbedding.result(task: task)
      end
    end
    stub_const('Legion::LLM::Call::Embeddings', embeddings_mod)
  end

  describe '.query' do
    context 'when local service is available' do
      let(:db) { Sequel.sqlite }

      before do
        db.create_table(:apollo_entries) do
          primary_key :id
          %i[content content_type source_agent tags knowledge_domain status access_scope embedding embedding_space_id embedding_provenance].each do |column|
            String column
          end
          Integer :identity_principal_id
          Integer :identity_id
          Integer :embedding_dimensions
          Integer :access_count, default: 0
          Float :confidence
          DateTime :created_at
          DateTime :updated_at
        end
        db.create_table(:apollo_access_log) do
          primary_key :id
          Integer :entry_id
          String :agent_id
          String :action
        end
        db.create_table(:identities) do
          primary_key :id
          Integer :principal_id
        end
        db.create_table(:identity_group_memberships) do
          Integer :principal_id
          Integer :group_id
        end
        stub_const('Legion::Data::Model::Apollo::Entry', Class.new(Sequel::Model(db[:apollo_entries])))
        stub_const('Legion::Data::Model::Apollo::AccessLog', Class.new(Sequel::Model(db[:apollo_access_log])))
      end

      after { db.disconnect }

      it 'applies query and retrieval filters to actual local rows and records the query reader' do
        embedding = ApolloSpecEmbedding.result
        base = {
          content: 'eligible', content_type: 'fact', source_agent: 'writer', tags: '["vault","ruby"]',
          knowledge_domain: 'security', status: 'candidate', access_scope: 'private', identity_principal_id: 41,
          confidence: 0.8, embedding: Legion::JSON.dump(embedding[:vector]),
          embedding_space_id: embedding[:embedding_provenance][:space_id], embedding_dimensions: 2,
          embedding_provenance: Legion::JSON.dump(embedding[:embedding_provenance])
        }
        eligible = db[:apollo_entries].insert(base)
        [{ identity_principal_id: 42 }, { knowledge_domain: 'other' }, { source_agent: 'other' },
         { tags: '["vault"]' }, { status: 'confirmed' }, { confidence: 0.1 }].each do |excluded|
          db[:apollo_entries].insert(base.merge(excluded))
        end
        filters = { status: ['candidate'], domain: 'security', requesting_principal_id: 41,
                    tags: %w[vault ruby], tag_match: :all, exclude_source_agents: ['other'], min_confidence: 0.7 }
        query = described_class.query(text: 'test query', agent_id: 'reader', **filters)
        retrieval = described_class.retrieve(text: 'test query', **filters)

        expect(query).to include(success: true)
        expect(retrieval).to include(success: true)
        expect(query[:entries].map { |entry| entry[:id] }).to eq([eligible])
        expect(retrieval[:entries].map { |entry| entry[:id] }).to eq([eligible])
        expect(db[:apollo_access_log].select(:entry_id, :agent_id, :action).all).to eq(
          [{ entry_id: eligible, agent_id: 'reader', action: 'query' }]
        )
      end
    end

    context 'when only transport is available' do
      it 'delivers all request operations through the real message classes and local transport' do
        script = <<~'RUBY'
          require 'rspec'
          require 'spec_helper'
          require 'json'
          Legion::Transport::Connection.setup
          channel = Legion::Transport::Connection.session.create_channel
          Legion::Extensions::Apollo::Transport::Exchanges::Apollo.new('legion.apollo', channel: channel)
          queries = []
          ingests = []
          Legion::Transport::Local.subscribe('legion.apollo.query') { |payload| queries << Legion::JSON.load(payload) }
          Legion::Transport::Local.subscribe('legion.apollo.ingest') { |payload| ingests << Legion::JSON.load(payload) }
          request = Legion::Extensions::Apollo::Runners::Request
          metadata = {
            status: ['candidate'], domain: 'security', agent_id: 'reader', requesting_principal_id: 41,
            tags: ['vault'], tag_match: 'all', exclude_source_agents: ['other'],
            reply_to: 'request-replies', correlation_id: 'query-correlation'
          }
          provenance = {
            source_agent: 'writer', source_provider: 'anthropic', source_channel: 'chat',
            knowledge_domain: 'security', submitted_by: 'operator', submitted_from: 'terminal',
            content_hash: 'digest', context: { request_id: 'request-1' }, access_scope: 'private',
            identity_principal_id: 41, identity_id: nil, identity_canonical_name: 'operator@example.test',
            embedding: [0.1, 0.2]
          }
          module Legion::Identity
            module Process
              def self.resolved? = false
              def self.db_principal_id = 99
              def self.db_identity_id = 101
              def self.canonical_name = 'sender@example.test'
            end
          end
          results = [
            request.query(text: 'remote query', **metadata),
            request.retrieve(text: 'remote retrieval', **metadata),
            request.traverse(entry_id: 'entry-1', depth: 3, relation_types: ['supports'],
                             agent_id: 'reader', requesting_principal_id: 41, reply_to: 'request-replies', correlation_id: 'graph-correlation'),
            request.ingest(content: 'remote fact', content_type: 'fact', **provenance),
            request.ingest(content: 'sender-owned fact', content_type: 'fact'),
            request.ingest(content: 'anonymous fact', content_type: 'fact',
                           identity_principal_id: nil, identity_id: nil, identity_canonical_name: nil)
          ]
          Legion::Transport::Connection.shutdown
          puts "APOLLO_RESULT=#{JSON.generate(results: results, queries: queries, ingests: ingests)}"
        RUBY
        stdout, stderr, status = Open3.capture3(
          { 'LEGION_MODE' => 'lite' }, RbConfig.ruby, '-Ilib', '-Ispec', '-e', script,
          chdir: File.expand_path('../../../../..', __dir__)
        )
        line = stdout.lines.find { |output| output.start_with?('APOLLO_RESULT=') }
        raise "Request process failed: #{stderr}\n#{stdout}" unless status.success? && line

        state = Legion::JSON.load(line.delete_prefix('APOLLO_RESULT='))
        expect(state[:results]).to all(include(success: true, dispatched: 'transport'))
        query_metadata = {
          status: ['candidate'], domain: 'security', agent_id: 'reader', requesting_principal_id: 41,
          tags: ['vault'], tag_match: 'all', exclude_source_agents: ['other'],
          reply_to: 'request-replies', correlation_id: 'query-correlation'
        }
        expect(state[:queries]).to contain_exactly(
          include(action: 'query', query: 'remote query', **query_metadata),
          include(action: 'retrieve', query: 'remote retrieval', **query_metadata),
          include(action: 'traverse', entry_id: 'entry-1', depth: 3, relation_types: ['supports'],
                  agent_id: 'reader', requesting_principal_id: 41, reply_to: 'request-replies', correlation_id: 'graph-correlation')
        )
        expect(state[:ingests]).to contain_exactly(
          include(content: 'remote fact', content_type: 'fact', source_agent: 'writer', source_provider: 'anthropic',
                  source_channel: 'chat', knowledge_domain: 'security', submitted_by: 'operator', submitted_from: 'terminal',
                  content_hash: 'digest', context: { request_id: 'request-1' }, access_scope: 'private',
                  identity_principal_id: 41, identity_id: nil, identity_canonical_name: 'operator@example.test', embedding: [0.1, 0.2]),
          include(content: 'sender-owned fact', identity_principal_id: 99, identity_id: 101, identity_canonical_name: 'sender@example.test'),
          include(content: 'anonymous fact', identity_principal_id: nil, identity_id: nil, identity_canonical_name: nil)
        )
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
