# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/helpers/confidence'
require 'legion/extensions/apollo/helpers/similarity'
require 'legion/extensions/apollo/helpers/graph_query'
require 'legion/extensions/apollo/helpers/tag_normalizer'
require 'legion/extensions/apollo/helpers/writeback'
require 'legion/extensions/apollo/runners/knowledge'

RSpec.describe Legion::Extensions::Apollo::Runners::Knowledge do
  let(:runner) do
    obj = Object.new
    obj.extend(described_class)
    obj
  end

  before do
    hide_const('Legion::Data::Model::Apollo') if defined?(Legion::Data::Model::Apollo)
    %i[ApolloEntry ApolloRelation ApolloExpertise ApolloAccessLog].each do |name|
      hide_const("Legion::Data::Model::#{name}") if defined?(Legion::Data::Model) && Legion::Data::Model.const_defined?(name, false)
    end
    hide_const('Legion::Identity::Process') if defined?(Legion::Identity::Process)
    stub_const('Legion::LLM::Call::Embeddings', Module.new)
    allow(Legion::LLM::Call::Embeddings).to receive(:generate) do |task: :document, **|
      ApolloSpecEmbedding.result(task: task)
    end
    allow(Legion::Extensions::Apollo).to receive(:settings).and_return(Legion::Extensions::Apollo.default_settings)
  end

  shared_context 'persisted knowledge' do
    let(:database) { Sequel.sqlite }
    let(:entry_model) { Class.new(Sequel::Model(database[:apollo_entries])) }

    before do
      database.create_table(:apollo_entries) do
        primary_key :id
        String :content
        String :content_type
        String :content_hash
        String :status
        String :source_agent
        String :source_provider
        String :source_channel
        String :source_context
        String :tags
        String :knowledge_domain
        String :submitted_by
        String :submitted_from
        String :access_scope
        Integer :identity_principal_id
        Integer :identity_id
        String :identity_canonical_name
        String :embedding
        String :embedding_provenance
        String :embedding_space_id
        Integer :embedding_dimensions
        Float :confidence
        Integer :access_count, default: 0
        DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
        DateTime :updated_at
      end
      database.create_table(:apollo_expertise) do
        primary_key :id
        String :agent_id
        String :domain
        Float :proficiency
        Integer :entry_count
        DateTime :last_active_at
      end
      database.create_table(:apollo_access_logs) do
        primary_key :id
        Integer :entry_id
        String :agent_id
        String :action
      end
      database.create_table(:identities) do
        primary_key :id
        Integer :principal_id
      end
      database.create_table(:identity_group_memberships) do
        Integer :principal_id
        Integer :group_id
      end
      stub_const('Legion::Data::Model::ApolloEntry', entry_model)
      stub_const('Legion::Data::Model::ApolloExpertise', Class.new(Sequel::Model(database[:apollo_expertise])))
      stub_const('Legion::Data::Model::ApolloAccessLog', Class.new(Sequel::Model(database[:apollo_access_logs])))
    end

    after { database.disconnect }

    def persisted_entry(content: 'Ruby is interpreted', **attributes)
      embedding = ApolloSpecEmbedding.result
      entry_model.create(
        { content: content, content_type: 'fact', content_hash: Digest::SHA256.hexdigest(content),
          status: 'confirmed', source_agent: 'worker', tags: Legion::JSON.dump(['ruby']),
          knowledge_domain: 'general', access_scope: 'global', confidence: 0.8,
          embedding: Legion::JSON.dump(embedding[:vector]),
          embedding_provenance: Legion::JSON.dump(embedding[:embedding_provenance]),
          embedding_space_id: embedding[:embedding_provenance][:space_id], embedding_dimensions: 2 }.merge(attributes)
      )
    end
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

    it 'falls back to :observation for unrecognized content_type' do
      result = runner.store_knowledge(content: 'test', content_type: 'invalid_type')
      expect(result[:content_type]).to eq(:observation)
    end

    it 'normalizes LLM-provided content_type "reasoning" to :concept' do
      result = runner.store_knowledge(content: 'test', content_type: 'reasoning')
      expect(result[:content_type]).to eq(:concept)
    end

    it 'normalizes "text" to :observation' do
      result = runner.store_knowledge(content: 'test', content_type: 'text')
      expect(result[:content_type]).to eq(:observation)
    end

    it 'normalizes "text/plain" to :observation' do
      result = runner.store_knowledge(content: 'test', content_type: 'text/plain')
      expect(result[:content_type]).to eq(:observation)
    end

    it 'strips leading colon from ":fact"' do
      result = runner.store_knowledge(content: 'test', content_type: ':fact')
      expect(result[:content_type]).to eq(:fact)
    end

    it 'normalizes "inference" to :association' do
      result = runner.store_knowledge(content: 'test', content_type: 'inference')
      expect(result[:content_type]).to eq(:association)
    end

    it 'accepts all valid CONTENT_TYPES unchanged' do
      %i[fact concept procedure association observation].each do |ct|
        result = runner.store_knowledge(content: 'test', content_type: ct)
        expect(result[:content_type]).to eq(ct)
      end
    end
  end

  describe '#query_knowledge' do
    it 'returns a query payload hash' do
      result = runner.query_knowledge(query: 'PKI configuration')
      expect(result[:action]).to eq(:query)
      expect(result[:query]).to eq('PKI configuration')
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
    it 'retains the client action envelope without claiming a completed service mutation' do
      result = runner.deprecate_entry(entry_id: 'uuid-123', reason: 'outdated')
      expect(result[:action]).to eq(:deprecate)
      expect(result).not_to have_key(:success)
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
      include_context 'persisted knowledge'

      it 'persists a novel candidate that can be retrieved in the generated embedding space' do
        result = host.handle_ingest(content: 'Ruby is great', content_type: 'fact',
                                    tags: ['Ruby'], source_agent: 'agent-1')

        expect(result).to include(success: true, status: 'candidate', corroborated: false)
        retrieved = host.retrieve_relevant(query: 'Ruby', min_confidence: 0.0)
        expect(retrieved).to include(success: true, entries: [include(id: result[:entry_id], content: 'Ruby is great', tags: ['ruby'])])
        expect(database[:apollo_access_logs].all).to contain_exactly(
          include(entry_id: result[:entry_id], agent_id: 'agent-1', action: 'ingest')
        )
      end

      it 'sanitizes null bytes and invalid UTF-8 before content becomes queryable' do
        content = "hello\x00\xC3(world".dup.force_encoding(Encoding::UTF_8)
        result = host.handle_ingest(content: content, content_type: 'fact')

        expect(result[:success]).to be true
        expect(host.handle_query(query: '', min_confidence: 0.0)[:entries]).to contain_exactly(include(content: 'hello(world'))
      end

      context 'content hash dedup' do
        let!(:existing_entry) { persisted_entry(content: 'test', content_hash: 'same-hash') }

        it 'reuses a provenanced active entry without requiring an embedding provider' do
          expect(Legion::LLM::Call::Embeddings).not_to receive(:generate)

          result = host.handle_ingest(content: 'test', content_hash: 'same-hash')

          expect(result).to include(success: true, deduped: true, entry_id: existing_entry.id)
          expect(entry_model.count).to eq(1)
          expect(existing_entry.refresh.confidence).to be > 0.8
        end

        it 'regenerates legacy embeddings before reporting a duplicate as reusable' do
          existing_entry.update(embedding_provenance: nil, embedding_space_id: nil, embedding_dimensions: nil)

          result = host.handle_ingest(content: 'test', content_hash: 'same-hash')

          expect(result).to include(success: true, deduped: true, entry_id: existing_entry.id)
          expect(host.retrieve_relevant(query: 'test')[:entries]).to contain_exactly(include(id: existing_entry.id))
          expect(entry_model.count).to eq(1)
        end

        it 'does not report dedup success or boost confidence when legacy regeneration fails' do
          existing_entry.update(embedding_provenance: nil, embedding_space_id: nil)
          allow(Legion::LLM::Call::Embeddings).to receive(:generate).and_raise(IOError, 'provider unavailable')

          result = host.handle_ingest(content: 'test', content_hash: 'same-hash')

          expect(result).to include(success: false, error: include('provider unavailable'))
          expect(existing_entry.refresh.confidence).to eq(0.8)
          expect(existing_entry.embedding_provenance).to be_nil
        end

        it 'does not reuse another principal or scope with the same hash' do
          existing_entry.update(access_scope: 'private', identity_principal_id: 7)

          result = host.handle_ingest(content: 'test', content_hash: 'same-hash',
                                      access_scope: 'private', identity_principal_id: 8)

          expect(result).to include(success: true, corroborated: false)
          expect(result[:entry_id]).not_to eq(existing_entry.id)
          expect(host.retrieve_relevant(query: 'test', min_confidence: 0.0,
                                        requesting_principal_id: 8)[:entries]).to contain_exactly(include(id: result[:entry_id]))
        end

        it 'does not deduplicate against an archived entry' do
          existing_entry.update(status: 'archived')
          result = host.handle_ingest(content: 'test', content_hash: 'same-hash')

          expect(result).to include(success: true, status: 'candidate')
          expect(result[:entry_id]).not_to eq(existing_entry.id)
        end

        it 'returns the concurrent winner after an insert uniqueness conflict' do
          winner_values = existing_entry.values.except(:id)
          existing_entry.destroy
          winner_id = nil
          allow(entry_model).to receive(:create).and_raise(Sequel::UniqueConstraintViolation, 'duplicate hash')
          # Make the competing row visible after the pre-check but before the insert savepoint.
          allow(database).to receive(:transaction).and_wrap_original do |original, **options, &block|
            winner_id = database[:apollo_entries].insert(winner_values) if options[:savepoint]
            original.call(**options, &block)
          end

          result = host.handle_ingest(content: 'test', content_hash: 'same-hash')

          expect(result).to include(success: true, entry_id: winner_id)
        end

        it 'returns failure when a uniqueness conflict has no visible winner' do
          existing_entry.destroy
          allow(entry_model).to receive(:create).and_raise(Sequel::UniqueConstraintViolation, 'duplicate hash')

          expect(host.handle_ingest(content: 'test', content_hash: 'same-hash')).to include(
            success: false, error: 'duplicate hash'
          )
          expect(entry_model.count).to eq(0)
        end
      end

      it 'rejects private writes without an explicit usable owner' do
        result = host.handle_ingest(content: 'private fact', access_scope: 'private', identity_principal_id: nil)

        expect(result).to include(success: false, error: 'identity_required')
        expect(entry_model.count).to eq(0)
      end
    end

    context 'when Sequel raises an error' do
      before do
        stub_const('Legion::Data::Model::ApolloEntry', Class.new)
        stub_const('Legion::Data::Model::ApolloExpertise', Class.new)
        stub_const('Legion::Data::Model::ApolloAccessLog', Class.new)
        allow(Legion::Data::Model::ApolloEntry).to receive(:where)
          .and_raise(Sequel::Error, 'connection lost')
      end

      it 'returns a structured error' do
        allow(host).to receive(:handle_exception)

        result = host.handle_ingest(content: 'test', content_type: 'fact', source_agent: 'a')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('connection lost')
      end
    end

    context 'invalid content' do
      it 'returns an actionable failure for missing content' do
        expect(host.handle_ingest(content: nil)).to include(success: false, error: 'content is required')
      end

      it 'does not allow newline-bearing tags to forge warning log lines' do
        logger = double('logger', debug: nil, warn: nil)
        allow(host).to receive(:log).and_return(logger)

        host.handle_ingest(content: nil, tags: ["evil\nFAKE LOG LINE", 'normal'])

        expect(logger).to have_received(:warn) do |message|
          expect(message).to include('evil FAKE LOG LINE')
          expect(message).not_to include("\n")
        end
      end
    end

    context 'contradiction detection' do
      include_context 'persisted knowledge'

      it 'returns accepted ingestion without synchronous contradiction results when disabled' do
        expect(host.handle_ingest(content: 'test fact')).to include(success: true, contradictions: [])
      end

      it 'queues only the persisted entry identity when detection is enabled' do
        Legion::Extensions::Apollo.settings[:contradiction][:enabled] = true
        scanner = Class.new do
          def self.enqueue(entry_id:, **)
            (@pending ||= []) << entry_id
          end

          def self.pending(**) = @pending || []
        end
        stub_const('Legion::Extensions::Apollo::Actor::ContradictionScanner', scanner)

        result = host.handle_ingest(content: 'enabled test')

        expect(result).to include(success: true, contradictions: [])
        queued = scanner.pending.map { |entry_id| entry_model[entry_id] }
        expect(queued.map(&:content)).to eq(['enabled test'])
        expect(queued.first.id).to eq(result[:entry_id])
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

    context 'when semantic query access logging is unavailable' do
      let(:mock_entry_class) { double('ApolloEntry') }

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
        hide_const('Legion::Data::Model::ApolloAccessLog') if defined?(Legion::Data::Model::ApolloAccessLog)
        hide_const('Legion::Data::Model::Apollo::AccessLog') if defined?(Legion::Data::Model::Apollo::AccessLog)
      end

      it 'fails before embedding, lookup, or confidence mutation' do
        expect(mock_entry_class).not_to receive(:db)
        expect(Legion::LLM::Call::Embeddings).not_to receive(:generate)

        expect(host.handle_query(query: 'semantic query')).to include(
          success: false, error: 'apollo_data_not_available'
        )
      end
    end

    context 'when Apollo data is available' do
      let(:mock_entry_class) { double('ApolloEntry') }
      let(:mock_access_log_class) { double('ApolloAccessLog') }
      let(:mock_db) { double('db', database_type: :postgres) }
      let(:sample_entries) do
        [{ id: 'uuid-1', content: 'Ruby is interpreted', content_type: 'fact',
           confidence: 0.8, distance: 0.15, tags: ['ruby'], source_agent: 'agent-1',
           access_count: 3 }]
      end

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
        stub_const('Legion::Data::Model::ApolloAccessLog', mock_access_log_class)
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
    end

    context 'when no results found' do
      let(:mock_entry_class) { double('ApolloEntry') }
      let(:mock_db) { double('db', database_type: :postgres) }

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
        stub_const('Legion::Data::Model::ApolloAccessLog', Class.new)
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

    context 'when query is browse-shaped' do
      include_context 'persisted knowledge'

      let!(:candidate) { persisted_entry(content: 'Candidate fact', status: 'candidate') }
      let!(:confirmed) { persisted_entry(content: 'Confirmed fact', tags: '["clinical"]', knowledge_domain: 'clinical') }

      it 'includes candidates without generating an embedding' do
        expect(Legion::LLM::Call::Embeddings).not_to receive(:generate)

        result = host.handle_query(query: 'x')

        expect(result).to include(success: true, mode: :browse)
        expect(result[:entries].map { |entry| entry[:id] }).to contain_exactly(candidate.id, confirmed.id)
      end

      it 'honors an explicit confirmed status filter' do
        result = host.handle_query(query: 'x', status: [:confirmed])

        expect(result[:entries]).to contain_exactly(include(id: confirmed.id))
      end

      it 'intersects tags and domain filters' do
        expect(host.handle_query(query: 'x', tags: ['clinical'], domain: 'clinical')[:entries])
          .to contain_exactly(include(id: confirmed.id))
        expect(host.handle_query(query: 'x', tags: ['ruby'], domain: 'clinical')[:entries]).to eq([])
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
      let(:mock_db) { double('db', database_type: :postgres) }
      let(:sample_entries) do
        [{ id: 'uuid-1', content: 'fact', content_type: 'fact',
           confidence: 0.7, distance: 0.2, tags: ['ruby'], source_agent: 'agent-1' }]
      end

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
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
      include_context 'persisted knowledge'

      let!(:clinical_entry) { persisted_entry(content: 'treatment', knowledge_domain: 'clinical_care') }
      let!(:claims_entry) { persisted_entry(content: 'denial', knowledge_domain: 'claims_optimization') }

      before do
        allow(Legion::Data).to receive(:connection).and_return(database)
        persisted_entry(content: 'private treatment', knowledge_domain: 'clinical_care',
                        access_scope: 'private', identity_principal_id: 7)
      end

      it 'filters entries by domain compatibility and excludes private knowledge' do
        result = host.prepare_mesh_export(target_domain: 'clinical_care')

        expect(result).to include(success: true, target_domain: 'clinical_care')
        expect(result[:entries]).to contain_exactly(include(id: clinical_entry.id))
      end

      it 'allows all public domains when target is general' do
        result = host.prepare_mesh_export(target_domain: 'general')

        expect(result[:entries].map { |entry| entry[:id] }).to contain_exactly(clinical_entry.id, claims_entry.id)
      end

      it 'restricts claims_optimization to only claims entries' do
        result = host.prepare_mesh_export(target_domain: 'claims_optimization')

        expect(result[:entries]).to contain_exactly(include(id: claims_entry.id))
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
      include_context 'persisted knowledge'

      before { allow(Legion::Data).to receive(:connection).and_return(database) }

      it 'deletes unconfirmed knowledge and redacts identity without erasing corroborated content or other agents' do
        candidate = persisted_entry(content: 'unconfirmed', status: 'candidate', source_agent: 'agent-dead')
        confirmed = persisted_entry(content: 'corroborated', source_agent: 'agent-dead',
                                    identity_principal_id: 7, identity_id: 9, identity_canonical_name: 'private-name')
        other = persisted_entry(content: 'other agent', source_agent: 'agent-alive')

        result = host.handle_erasure_request(agent_id: 'agent-dead')

        expect(result).to include(deleted: 1, redacted: 1, agent_id: 'agent-dead')
        expect(entry_model[candidate.id]).to be_nil
        expect(confirmed.refresh.values).to include(content: 'corroborated', source_agent: 'redacted',
                                                    identity_principal_id: nil, identity_id: nil, identity_canonical_name: nil)
        expect(other.refresh.source_agent).to eq('agent-alive')
      end
    end

    context 'when Sequel raises an error' do
      before do
        stub_const('Legion::Data', Module.new)
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
