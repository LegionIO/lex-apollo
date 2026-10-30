# frozen_string_literal: true

require 'sinatra/base'
require 'open3'
require 'rbconfig'
require 'json'

require 'spec_helper'
require 'legion/extensions/apollo/api'

RSpec.describe Legion::Extensions::Apollo::Api do
  describe '.stats_payload' do
    let(:entry_model) { class_double('Legion::Data::Model::ApolloEntry') }
    let(:relation_model) { class_double('Legion::Data::Model::ApolloRelation', count: 4) }
    let(:status_counts) do
      instance_double(
        'StatusCounts',
        all: [
          { status: 'candidate', count: 2 },
          { status: 'confirmed', count: 3 },
          { status: 'archived', count: 1 }
        ]
      )
    end
    let(:content_type_counts) do
      instance_double(
        'ContentTypeCounts',
        all: [
          { content_type: 'document_chunk', count: 5 },
          { content_type: 'observation', count: 1 }
        ]
      )
    end
    let(:active_entries) { instance_double('ActiveEntries', count: 5) }
    let(:recent_entries) { instance_double('RecentEntries', count: 2) }

    before do
      stub_const('Legion::Data::Model::ApolloEntry', entry_model)
      stub_const('Legion::Data::Model::ApolloRelation', relation_model)
      allow(entry_model).to receive(:count).and_return(6)
      allow(entry_model).to receive(:avg).with(:confidence).and_return(0.81234)
      allow(entry_model).to receive(:exclude).with(status: 'archived').and_return(active_entries)
      allow(entry_model).to receive(:where).and_return(recent_entries)
      allow(entry_model).to receive(:group_and_count).with(:status).and_return(status_counts)
      allow(entry_model).to receive(:group_and_count).with(:content_type).and_return(content_type_counts)
    end

    it 'returns the health UI metrics expected by Interlink' do
      payload = described_class.stats_payload(now: Time.utc(2026, 4, 28, 12, 0, 0))

      expect(payload).to include(
        total_entries:   6,
        recent_24h:      2,
        avg_confidence:  0.812,
        total_relations: 4
      )
      expect(payload[:by_status]).to include(
        'candidate' => 2,
        'confirmed' => 3,
        'archived'  => 1,
        'active'    => 5
      )
      expect(payload[:by_content_type]).to eq(
        'document_chunk' => 5,
        'observation'    => 1
      )
    end

    it 'keeps entry statistics available when the optional relation model is absent' do
      hide_const('Legion::Data::Model::ApolloRelation') if defined?(Legion::Data::Model::ApolloRelation)
      hide_const('Legion::Data::Model::Apollo::Relation') if defined?(Legion::Data::Model::Apollo::Relation)

      payload = described_class.stats_payload(now: Time.utc(2026, 4, 28, 12, 0, 0))

      expect(payload).to include(total_entries: 6, recent_24h: 2, avg_confidence: 0.812)
      expect(payload).not_to have_key(:total_relations)
    end

    context 'when legion-data exposes namespaced Apollo models' do
      before do
        hide_const('Legion::Data::Model::ApolloEntry') if defined?(Legion::Data::Model::ApolloEntry)
        hide_const('Legion::Data::Model::ApolloRelation') if defined?(Legion::Data::Model::ApolloRelation)
        stub_const('Legion::Data::Model::Apollo::Entry', entry_model)
        stub_const('Legion::Data::Model::Apollo::Relation', relation_model)
      end

      it 'uses the namespaced models for stats' do
        payload = described_class.stats_payload(now: Time.utc(2026, 4, 28, 12, 0, 0))

        expect(payload).to include(
          total_entries:   6,
          recent_24h:      2,
          avg_confidence:  0.812,
          total_relations: 4
        )
      end
    end

    it 'returns an apollo data error when the entry model is unavailable' do
      hide_const('Legion::Data::Model::ApolloEntry')

      expect(described_class.stats_payload).to eq(error: 'apollo_data_not_available')
    end
  end

  describe 'HTTP identity boundaries' do
    let(:http_script) do
      <<~'RUBY'
        require 'sequel'
        require 'sequel/extensions/pg_array'
        require 'rspec'
        require 'sinatra/base'
        require 'rack/mock'
        require 'spec_helper'
        require 'json'
        require 'legion/extensions/apollo/api'
        db = Sequel.sqlite
        db.create_table(:apollo_entries) do
          primary_key :id
          %i[content content_type source_agent source_provider source_channel source_context tags status
             knowledge_domain submitted_by submitted_from content_hash access_scope identity_canonical_name embedding].each do |column|
            String column
          end
          Float :confidence
          Integer :identity_principal_id
          Integer :identity_id
          DateTime :created_at
          DateTime :updated_at
        end
        db.create_table(:apollo_expertise) do
          primary_key :id
          String :agent_id
          String :domain
          Float :proficiency
          Integer :entry_count
          DateTime :last_active_at
        end
        db.create_table(:apollo_access_log) do
          primary_key :id
          Integer :entry_id
          String :agent_id
          String :action
        end
        db.create_table(:identity_principals) do
          primary_key :id
          String :canonical_name
          String :kind
          TrueClass :active
        end
        db.create_table(:identity_providers) do
          primary_key :id
          String :name
        end
        db.create_table(:identities) do
          primary_key :id
          Integer :principal_id
          Integer :provider_id
          String :provider_identity_key
          TrueClass :active
        end
        db.create_table(:identity_group_memberships) do
          Integer :principal_id
          Integer :group_id
        end
        Legion::Data.const_set(:Model, Module.new) unless defined?(Legion::Data::Model)
        Legion::Data::Model.const_set(:Apollo, Module.new)
        { Entry: :apollo_entries, Expertise: :apollo_expertise, AccessLog: :apollo_access_log }.each do |name, table|
          Legion::Data::Model::Apollo.const_set(name, Class.new(Sequel::Model(db[table])))
        end
        Legion::Data::Model.const_set(:Identity, Module.new)
        { Principal: :identity_principals, Provider: :identity_providers, Identity: :identities }.each do |name, table|
          Legion::Data::Model::Identity.const_set(name, Class.new(Sequel::Model(db[table])))
        end
        Legion::Data.define_singleton_method(:connection) { db }
        Legion.const_set(:Identity, Module.new) unless defined?(Legion::Identity)
        Legion::Identity.const_set(:Process, Module.new)
        Legion::Identity::Process.define_singleton_method(:db_principal_id) { 999 }
        Legion::Identity::Process.define_singleton_method(:db_identity_id) { 998 }
        Legion::Identity::Process.define_singleton_method(:canonical_name) { 'service-node' }
        db[:identity_principals].insert(id: 42, canonical_name: 'alice', kind: 'human', active: true)
        db[:identity_providers].insert(id: 3, name: 'jwt')
        db[:identities].insert(id: 7, principal_id: 42, provider_id: 3, provider_identity_key: '900', active: true)
        base = { content_type: 'fact', status: 'confirmed', confidence: 0.8, access_scope: 'global',
                 source_agent: 'human', knowledge_domain: 'engineering', source_context: '{}', created_at: Time.now }
        [
          { id: 1, content: 'public evidence' },
          { id: 2, content: 'alice evidence', access_scope: 'private', identity_principal_id: 42 },
          { id: 3, content: 'mallory evidence', access_scope: 'private', identity_principal_id: 99 },
          { id: 4, content: 'server evidence', access_scope: 'private', identity_principal_id: 999 },
          { id: 5, content: 'weak evidence', confidence: 0.2 },
          { id: 6, content: 'excluded producer', source_agent: 'blocked-agent' },
          { id: 7, content: 'unconfirmed evidence', status: 'candidate' },
          { id: 8, content: 'other domain', knowledge_domain: 'other' }
        ].each { |row| db[:apollo_entries].insert(base.merge(row)) }
        input = ::JSON.parse($stdin.read, symbolize_names: true)
        request_type = Struct.new(:canonical_name, :kind, :principal_id, :source, keyword_init: true)
        http = Rack::MockRequest.new(Legion::Extensions::Apollo::Api)
        before = db[:apollo_entries].order(:id).all
        responses = input[:requests].map do |options|
          env = { 'CONTENT_TYPE' => 'application/json' }
          if options[:identity]
            canonical = options[:identity] == 'unmapped' ? 'unknown' : 'alice'
            env['legion.principal'] = request_type.new(canonical_name: canonical, kind: :human, principal_id: '900', source: :jwt)
            env['legion.auth'] = { sub: '900' } unless options[:identity] == 'system'
          end
          env[:input] = ::JSON.generate(options[:body]) if options.key?(:body)
          env[:input] = options[:raw_body] if options.key?(:raw_body)
          response = http.post(options[:path], env)
          { status: response.status, body: ::JSON.parse(response.body) }
        end
        state = { responses: responses, before: before, entries: db[:apollo_entries].order(:id).all,
                  expertise: db[:apollo_expertise].count, access_logs: db[:apollo_access_log].count }
        puts "APOLLO_RESULT=#{::JSON.generate(state)}"
      RUBY
    end
    let(:forged_identity) do
      { identity_principal_id: 99, identity_id: 88, identity_canonical_name: 'mallory',
        requesting_principal_id: 99, principal_id: 99 }
    end
    let(:browse_body) do
      forged_identity.merge(query: '', min_confidence: 0.7, exclude_source_agents: ['blocked-agent'],
                            status: 'confirmed', domain: 'engineering')
    end

    def http_state(requests:, **)
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, '-Ilib', '-Ispec', '-e', http_script,
        chdir: File.expand_path('../../../..', __dir__), stdin_data: JSON.generate(requests: requests)
      )
      line = stdout.lines.find { |output| output.start_with?('APOLLO_RESULT=') }
      raise "HTTP identity process failed: #{stderr}\n#{stdout}" unless status.success? && line

      JSON.parse(line.delete_prefix('APOLLO_RESULT='), symbolize_names: true)
    end

    it 'keeps anonymous, synthesized-system, and unmapped callers global-only despite forged ownership' do
      requests = [nil, 'system', 'unmapped'].map do |identity|
        { path: '/api/apollo/query', body: browse_body.merge(access_scope: 'private'), identity: identity }
      end
      state = http_state(requests: requests)

      expect(state[:responses].map { |response| response[:status] }).to eq([200, 200, 200])
      state[:responses].each do |response|
        expect(response[:body][:entries].map { |entry| entry[:content] }).to eq(['public evidence'])
      end
    end

    it 'reads the authenticated canonical owners private content without admitting a forged owner or process identity' do
      state = http_state(requests: [{ path: '/api/apollo/query', body: browse_body, identity: 'authenticated' }])
      response = state[:responses].first

      expect(response[:status]).to eq(200)
      expect(response[:body][:entries].map { |entry| entry[:content] }).to contain_exactly('public evidence', 'alice evidence')
    end

    it 'denies anonymous restricted writes and invalid scopes without persisting rows or side effects' do
      requests = %w[private team invalid].map do |scope|
        { path: '/api/apollo/ingest', body: forged_identity.merge(content: 'secret', content_type: 'fact', access_scope: scope) }
      end
      state = http_state(requests: requests)

      expect(state[:responses].map { |response| response[:status] }).to eq([403, 403, 400])
      expect(state[:entries]).to eq(state[:before])
      expect(state).to include(expertise: 0, access_logs: 0)
    end

    it 'persists authenticated private ownership and provenance rather than forged body identity' do
      provenance = {
        content: 'new private knowledge', content_type: 'fact', access_scope: 'private',
        source_agent: 'agent-a', source_provider: 'provider-a', source_channel: 'channel-a',
        knowledge_domain: 'engineering', submitted_by: 'original author', submitted_from: 'document:12',
        context: { citation: 'page 4' }
      }
      state = http_state(requests: [{ path: '/api/apollo/ingest', body: provenance.merge(forged_identity), identity: 'authenticated' }])
      response = state[:responses].first
      entry = state[:entries].find { |row| row[:id] == response[:body][:entry_id] }

      expect(response[:status]).to eq(201)
      expect(entry).to include(provenance.except(:context).merge(identity_principal_id: 42, identity_id: 7,
                                                                 identity_canonical_name: 'alice'))
      expect(JSON.parse(entry[:source_context], symbolize_names: true)).to include(citation: 'page 4')
      expect(state).to include(expertise: 1, access_logs: 1)
    end

    it 'persists anonymous global content without inheriting the receiving process identity' do
      state = http_state(requests: [{ path: '/api/apollo/ingest',
                                      body: forged_identity.merge(content: 'new public knowledge', content_type: 'fact') }])
      response = state[:responses].first
      entry = state[:entries].find { |row| row[:id] == response[:body][:entry_id] }

      expect(response[:status]).to eq(201)
      expect(entry).to include(content: 'new public knowledge', access_scope: 'global',
                               identity_principal_id: nil, identity_id: nil, identity_canonical_name: nil)
    end

    it 'hides foreign deprecation targets and leaves their persisted contents unchanged' do
      state = http_state(requests: [
                           { path: '/api/apollo/entries/2/deprecate' },
                           { path: '/api/apollo/entries/3/deprecate', identity: 'authenticated',
                             body: forged_identity.merge(reason: 'forged ownership') }
                         ])

      expect(state[:responses]).to all(include(status: 404, body: hash_including(error: 'entry_not_found')))
      expect(state[:entries]).to eq(state[:before])
    end

    it 'retains owner deprecation and JSON errors for missing bodies and malformed JSON' do
      state = http_state(requests: [
                           { path: '/api/apollo/entries/2/deprecate', identity: 'authenticated' },
                           { path: '/api/apollo/query' },
                           { path: '/api/apollo/query', raw_body: '{' }
                         ])

      expect(state[:responses].map { |response| response[:status] }).to eq([200, 400, 400])
      entry = state[:entries].find { |row| row[:id] == 2 }
      expect(entry[:status]).to eq('archived')
      expect(JSON.parse(entry[:source_context], symbolize_names: true)).to include(deprecation_reason: 'deprecated via API')
      expect(state[:responses][1][:body]).to have_key(:error)
      expect(state[:responses][2][:body]).to have_key(:error)
    end
  end
end
