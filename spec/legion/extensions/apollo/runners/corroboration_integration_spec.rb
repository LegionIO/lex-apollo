# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'
require 'json'

RSpec.describe 'Apollo corroboration persistence' do
  let(:candidate) do
    { id: 1, status: 'candidate', content_type: 'fact', knowledge_domain: 'clinical', access_scope: 'global',
      confidence: 0.5, source_provider: 'openai', source_channel: 'source-a' }
  end
  let(:confirmed) do
    { id: 2, status: 'confirmed', content_type: 'fact', knowledge_domain: 'clinical', access_scope: 'global',
      confidence: 0.8, source_provider: 'claude', source_channel: 'source-b' }
  end

  let(:corroboration_script) do
    <<~'RUBY'
      require 'sequel'
      require 'rspec'
      require 'spec_helper'
      require 'json'
      db = Sequel.sqlite
      db.create_table(:apollo_entries) do
        primary_key :id
        String :status
        String :content_type
        String :knowledge_domain
        String :access_scope
        Integer :identity_principal_id
        Integer :identity_id
        String :source_provider
        String :source_channel
        String :embedding
        Float :confidence
        DateTime :confirmed_at
        DateTime :updated_at
      end
      db.create_table(:apollo_relations) do
        primary_key :id
        Integer :from_entry_id
        Integer :to_entry_id
        String :relation_type
        String :source_agent
        Float :weight
      end
      db.create_table(:identities) do
        Integer :id
        Integer :principal_id
      end
      db.create_table(:identity_group_memberships) do
        Integer :principal_id
        Integer :group_id
      end
      Legion::Data.const_set(:Model, Module.new) unless defined?(Legion::Data::Model)
      Legion::Data::Model.const_set(:Apollo, Module.new)
      Legion::Data::Model::Apollo.const_set(:Entry, Class.new(Sequel::Model(db[:apollo_entries])))
      Legion::Data::Model::Apollo.const_set(:Relation, Class.new(Sequel::Model(db[:apollo_relations])))
      input = ::JSON.parse($stdin.read, symbolize_names: true)
      input[:entries].each { |entry| db[:apollo_entries].insert(entry.merge(embedding: '[1.0,0.0]')) }
      input[:memberships].each { |membership| db[:identity_group_memberships].insert(membership) }
      input[:identities].each { |identity| db[:identities].insert(identity) }
      runner = Object.new.extend(Legion::Extensions::Apollo::Runners::Maintenance)
      result = runner.check_corroboration
      state = { result: result, entries: db[:apollo_entries].order(:id).all, relations: db[:apollo_relations].all }
      puts "APOLLO_RESULT=#{::JSON.generate(state)}"
    RUBY
  end

  def corroboration_state(entries:, memberships: [], identities: [])
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, '-Ilib', '-Ispec', '-e', corroboration_script,
      chdir:      File.expand_path('../../../../..', __dir__),
      stdin_data: JSON.generate(entries: entries, memberships: memberships, identities: identities)
    )
    line = stdout.lines.find { |output| output.start_with?('APOLLO_RESULT=') }
    raise "Corroboration process failed: #{stderr}\n#{stdout}" unless status.success? && line

    JSON.parse(line.delete_prefix('APOLLO_RESULT='), symbolize_names: true)
  end

  it 'rejects other domains, inactive states, other content types, and dependent sources' do
    state = corroboration_state(entries: [
                                  candidate,
                                  confirmed.merge(knowledge_domain: 'general'),
                                  confirmed.merge(id: 3, status: 'archived'),
                                  confirmed.merge(id: 4, status: 'disputed'),
                                  confirmed.merge(id: 5, content_type: 'concept'),
                                  confirmed.merge(id: 6, source_provider: 'openai'),
                                  confirmed.merge(id: 7, source_channel: 'source-a')
                                ])

    expect(state[:result]).to include(success: true, promoted: 0)
    expect(state[:entries].first).to include(status: 'candidate', confidence: 0.5)
    expect(state[:relations]).to eq([])
  end

  it 'corroborates private knowledge only with eligible evidence owned by the same principal' do
    state = corroboration_state(entries: [
                                  candidate.merge(access_scope: 'private', identity_principal_id: 42),
                                  confirmed.merge(access_scope: 'private', identity_principal_id: 99),
                                  confirmed.merge(id: 3, access_scope: 'private', identity_principal_id: 42, knowledge_domain: 'other'),
                                  confirmed.merge(id: 4, access_scope: 'private', identity_principal_id: 42)
                                ])

    expect(state[:result]).to include(success: true, promoted: 1)
    expect(state[:entries].first).to include(status: 'confirmed', confidence: 0.8)
    expect(state[:relations]).to contain_exactly(hash_including(from_entry_id: 1, to_entry_id: 4, relation_type: 'similar_to'))
  end

  it 'requires shared identity-group membership for team corroboration' do
    state = corroboration_state(
      entries:     [candidate.merge(access_scope: 'team', identity_principal_id: 42),
                    confirmed.merge(access_scope: 'team', identity_principal_id: 77),
                    confirmed.merge(id: 3, access_scope: 'team', identity_principal_id: 99)],
      memberships: [{ principal_id: 42, group_id: 7 }, { principal_id: 99, group_id: 7 }, { principal_id: 77, group_id: 8 }]
    )

    expect(state[:result]).to include(success: true, promoted: 1)
    expect(state[:relations]).to contain_exactly(hash_including(from_entry_id: 1, to_entry_id: 3))
  end

  it 'does not corroborate private knowledge with an unresolved owner' do
    state = corroboration_state(entries: [candidate.merge(access_scope: 'private'),
                                          confirmed.merge(access_scope: 'private', identity_principal_id: 42)])

    expect(state[:result]).to include(success: true, promoted: 0)
    expect(state[:entries].first[:status]).to eq('candidate')
    expect(state[:relations]).to eq([])
  end

  it 'does not use private evidence to promote a global entry' do
    state = corroboration_state(entries: [candidate.merge(identity_principal_id: 42),
                                          confirmed.merge(access_scope: 'private', identity_principal_id: 42)])

    expect(state[:result]).to include(success: true, promoted: 0)
    expect(state[:entries].first[:confidence]).to eq(0.5)
    expect(state[:relations]).to eq([])
  end

  it 'recognizes private ownership through the existing identity-to-principal mapping' do
    state = corroboration_state(
      entries:    [candidate.merge(access_scope: 'private', identity_principal_id: 42),
                   confirmed.merge(access_scope: 'private', identity_id: 70)],
      identities: [{ id: 70, principal_id: 42 }]
    )

    expect(state[:result]).to include(success: true, promoted: 1)
    expect(state[:relations]).to contain_exactly(hash_including(from_entry_id: 1, to_entry_id: 2))
  end
end
