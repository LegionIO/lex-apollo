# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'
require 'json'

RSpec.describe 'Apollo knowledge access boundaries' do
  let(:scope_script) do
    <<~'RUBY'
      require 'sequel'
      require 'rspec'
      require 'spec_helper'
      require 'json'
      db = Sequel.sqlite
      db.create_table(:apollo_entries) do
        primary_key :id
        String :content
        String :content_type
        String :status
        String :access_scope
        Integer :identity_principal_id
        Integer :identity_id
        Float :confidence
        String :tags
        String :source_agent
        String :knowledge_domain
        String :source_context
        DateTime :created_at
        DateTime :updated_at
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
      Legion::Data.define_singleton_method(:connection) { db }
      base = { content_type: 'fact', status: 'confirmed', confidence: 0.8, knowledge_domain: 'general', created_at: Time.now }
      rows = [
        { id: 1, content: 'public evidence', access_scope: 'global', source_agent: 'human' },
        { id: 2, content: 'owner evidence', access_scope: 'private', identity_principal_id: 42 },
        { id: 3, content: 'other owner', access_scope: 'private', identity_principal_id: 99 },
        { id: 4, content: 'shared team', access_scope: 'team', identity_principal_id: 77 },
        { id: 5, content: 'unrelated team', access_scope: 'team', identity_principal_id: 88 },
        { id: 6, content: 'identity alias', access_scope: 'private', identity_id: 7 },
        { id: 7, content: 'archived evidence', access_scope: 'global', status: 'archived' },
        { id: 8, content: 'weak evidence', access_scope: 'global', confidence: 0.2 },
        { id: 9, content: 'excluded producer', access_scope: 'global', source_agent: 'blocked-agent' }
      ]
      rows.each { |row| db[:apollo_entries].insert(base.merge(row)) }
      db[:identities].insert(id: 7, principal_id: 42)
      [{ principal_id: 42, group_id: 5 }, { principal_id: 77, group_id: 5 }, { principal_id: 88, group_id: 6 }].each do |row|
        db[:identity_group_memberships].insert(row)
      end
      runner = Object.new.extend(Legion::Extensions::Apollo::Runners::Knowledge)
      input = ::JSON.parse($stdin.read, symbolize_names: true)
      result = case input[:action]
               when 'browse'
                 runner.handle_query(query: '', requesting_principal_id: input[:principal], min_confidence: 0.7,
                                     exclude_source_agents: ['blocked-agent'])
               when 'deprecate'
                 runner.deprecate_entry(entry_id: 2, reason: 'retired', requesting_principal_id: input[:principal])
               when 'export'
                 runner.prepare_mesh_export(target_domain: 'general')
               end
      state = { result: result, private_status: db[:apollo_entries][id: 2][:status] }
      puts "APOLLO_RESULT=#{::JSON.generate(state)}"
    RUBY
  end

  def scoped_result(action:, principal: nil, **)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, '-Ilib', '-Ispec', '-e', scope_script,
      chdir: File.expand_path('../../../../..', __dir__), stdin_data: JSON.generate(action: action, principal: principal)
    )
    line = stdout.lines.find { |output| output.start_with?('APOLLO_RESULT=') }
    raise "Scoped knowledge process failed: #{stderr}\n#{stdout}" unless status.success? && line

    JSON.parse(line.delete_prefix('APOLLO_RESULT='), symbolize_names: true)
  end

  it 'keeps anonymous browse global-only while applying confidence and source exclusions' do
    result = scoped_result(action: 'browse', principal: 0)[:result]

    expect(result[:success]).to be true
    expect(result[:entries].map { |entry| entry[:id] }).to eq([1])
  end

  it 'includes owned private evidence and shared teams without admitting unrelated owners' do
    result = scoped_result(action: 'browse', principal: 42)[:result]

    expect(result[:success]).to be true
    expect(result[:entries].map { |entry| entry[:id] }).to contain_exactly(1, 2, 4, 6)
  end

  it 'does not disclose or mutate a private entry when deprecation is requested by another principal' do
    state = scoped_result(action: 'deprecate', principal: 99)

    expect(state[:result]).to include(success: false, error: 'entry_not_found')
    expect(state[:private_status]).to eq('confirmed')
  end

  it 'allows the owner to deprecate its private entry' do
    state = scoped_result(action: 'deprecate', principal: 42)

    expect(state[:result]).to include(success: true, status: 'archived')
    expect(state[:private_status]).to eq('archived')
  end

  it 'exports only global confirmed evidence, even without a requesting principal' do
    result = scoped_result(action: 'export')[:result]

    expect(result[:success]).to be true
    expect(result[:entries].map { |entry| entry[:id] }).to contain_exactly(1, 9)
  end
end
