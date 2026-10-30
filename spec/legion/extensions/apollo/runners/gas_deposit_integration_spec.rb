# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'
require 'json'

RSpec.describe 'Apollo GAS relation persistence' do
  let(:deposit_script) do
    <<~'RUBY'
      require 'sequel'
      require 'rspec'
      require 'spec_helper'
      require 'json'
      require 'legion/extensions/apollo/helpers/writeback'
      require 'legion/extensions/apollo/runners/gas'
      db = Sequel.sqlite
      db.create_table(:apollo_entries) do
        primary_key :id
        String :content
        String :content_hash, unique: true
        String :content_type
        String :status
        String :access_scope
        Integer :identity_principal_id
        Float :confidence
      end
      db.create_table(:apollo_relations) do
        primary_key :id
        foreign_key :from_entry_id, :apollo_entries, null: false
        foreign_key :to_entry_id, :apollo_entries, null: false
        String :relation_type
        String :source_agent
        Float :weight
        check(Sequel.~(relation_type: 'causes'))
      end
      db.create_table(:apollo_expertise) { primary_key :id }
      db.create_table(:apollo_access_logs) { primary_key :id }
      Legion::Data.const_set(:Model, Module.new) unless defined?(Legion::Data::Model)
      Legion::Data::Model.const_set(:Apollo, Module.new)
      { Entry: :apollo_entries, Relation: :apollo_relations, Expertise: :apollo_expertise,
        AccessLog: :apollo_access_logs }.each do |name, table|
        Legion::Data::Model::Apollo.const_set(name, Class.new(Sequel::Model(db[table])))
      end
      input = ::JSON.parse($stdin.read, symbolize_names: true)
      input[:entries].each do |entry|
        db[:apollo_entries].insert(entry.merge(content_hash: Legion::Extensions::Apollo::Helpers::Writeback.content_hash(entry[:content])))
      end
      knowledge = Legion::Extensions::Apollo::Runners::Knowledge
      knowledge.extend(knowledge)
      result = Legion::Extensions::Apollo::Runners::Gas.phase_deposit(
        input[:facts], [], input[:relations], [], { request_id: 'gas-regression' }
      )
      puts "APOLLO_RESULT=#{::JSON.generate(result: result, relations: db[:apollo_relations].all)}"
    RUBY
  end

  def gas_deposit_state(entries:, facts:, relations:)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, '-Ilib', '-Ispec', '-e', deposit_script,
      chdir:      File.expand_path('../../../../..', __dir__),
      stdin_data: JSON.generate(entries: entries, facts: facts, relations: relations)
    )
    line = stdout.lines.find { |output| output.start_with?('APOLLO_RESULT=') }
    raise "GAS deposit process failed: #{stderr}\n#{stdout}" unless status.success? && line

    JSON.parse(line.delete_prefix('APOLLO_RESULT='), symbolize_names: true)
  end

  it 'links successful deduplicated facts safely and continues after an independent relation write fails' do
    entry = { content_type: 'fact', status: 'candidate', access_scope: 'global', confidence: 0.5 }
    entries = [entry.merge(id: 1, content: 'stored fact'), entry.merge(id: 2, content: 'target evidence'),
               entry.merge(id: 3, content: 'private evidence', access_scope: 'private', identity_principal_id: 99),
               entry.merge(id: 4, content: 'second fact')]
    facts = [{ content: 'stored fact', content_type: :fact }, { content: '', content_type: :fact },
             { content: 'second fact', content_type: :fact }]
    relation = { from_content: 'stored fact', to_id: 2, relation_type: 'supports_by', confidence: 0.9 }
    relations = [relation, relation.dup, relation.merge(from_content: ''), relation.merge(to_id: 999),
                 relation.merge(to_id: 1), relation.merge(to_id: 3), relation.merge(confidence: 0.2),
                 relation.merge(relation_type: 'unsupported'), relation.merge(from_content: 'second fact', relation_type: 'causes'),
                 relation.merge(from_content: 'second fact', relation_type: 'depends_on')]

    state = gas_deposit_state(entries: entries, facts: facts, relations: relations)

    expect(state[:result]).to include(deposited: 2, failed: 1, facts: 2, synthesis: 0,
                                      relations: 2, relations_failed: 3, relations_skipped: 5)
    expect(state[:relations]).to contain_exactly(
      hash_including(from_entry_id: 1, to_entry_id: 2, relation_type: 'supports_by'),
      hash_including(from_entry_id: 4, to_entry_id: 2, relation_type: 'depends_on')
    )
  end
end
