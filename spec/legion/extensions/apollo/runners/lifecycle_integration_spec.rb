# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'
require 'json'

RSpec.describe 'Apollo service lifecycle mutations' do
  let(:lifecycle_script) do
    <<~'RUBY'
      require 'sequel'
      require 'sinatra/base'
      require 'rack/mock'
      require 'rspec'
      require 'spec_helper'
      require 'json'
      require 'legion/extensions/apollo/api'
      db = Sequel.sqlite
      db.create_table(:apollo_entries) do
        primary_key :id
        String :content
        String :content_type
        String :status
        String :access_scope, default: 'global'
        Float :confidence
        String :source_context
        String :embedding
        String :embedding_space_id
        Integer :embedding_dimensions
        String :embedding_provenance
        DateTime :created_at
        DateTime :updated_at
        DateTime :confirmed_at
        check(Sequel.lit("content != 'protected' OR status != 'archived'"))
      end
      Legion::Data.const_set(:Model, Module.new) unless defined?(Legion::Data::Model)
      Legion::Data::Model.const_set(:Apollo, Module.new)
      entry_model = Class.new(Sequel::Model(db[:apollo_entries]))
      Legion::Data::Model::Apollo.const_set(:Entry, entry_model)
      now = Time.now
      old = now - (100 * 86_400)
      attributes = { content_type: 'fact', status: 'candidate', confidence: 0.8,
                     source_context: ::JSON.generate(origin: 'preserve'), created_at: now, updated_at: nil }
      embedding = ApolloSpecEmbedding.result
      attributes.merge!(embedding: ::JSON.generate(embedding[:vector]), embedding_dimensions: embedding[:dimensions],
                        embedding_space_id: embedding[:embedding_provenance][:space_id],
                        embedding_provenance: ::JSON.generate(embedding[:embedding_provenance]))
      db[:apollo_entries].insert(attributes.merge(id: 1, content: 'target'))
      db[:apollo_entries].insert(attributes.merge(id: 2, content: 'protected'))
      db[:apollo_entries].insert(attributes.merge(id: 3, content: 'stale', confidence: 0.04, created_at: old))
      db[:apollo_entries].insert(attributes.merge(id: 4, content: 'touched', status: 'confirmed', confidence: 0.6,
                                                 created_at: old, updated_at: now))
      db[:apollo_entries].insert(attributes.merge(id: 5, content: 'already archived', status: 'archived', confidence: 0.7,
                                                 created_at: old))
      input = ::JSON.parse($stdin.read, symbolize_names: true)
      maintenance = Object.new.extend(Legion::Extensions::Apollo::Runners::Maintenance)
      case input[:operation]
      when 'deprecate'
        api = Rack::MockRequest.new(Legion::Extensions::Apollo::Api)
        payload = ::JSON.generate(reason: 'Verified replacement exists.')
        first = api.post('/api/apollo/entries/1/deprecate', 'CONTENT_TYPE' => 'application/json', input: payload)
        first_updated_at = entry_model[1].updated_at
        repeated = api.post('/api/apollo/entries/1/deprecate', 'CONTENT_TYPE' => 'application/json', input: payload)
        repeat_preserved_time = entry_model[1].updated_at == first_updated_at
        missing = api.post('/api/apollo/entries/999/deprecate')
        failed = api.post('/api/apollo/entries/2/deprecate', 'CONTENT_TYPE' => 'application/json', input: payload)
        malformed = api.post('/api/apollo/entries/1/deprecate', 'CONTENT_TYPE' => 'application/json', input: '{')
        Legion::Data::Model::Apollo.send(:remove_const, :Entry)
        unavailable = api.post('/api/apollo/entries/1/deprecate')
        Legion::Data::Model::Apollo.const_set(:Entry, entry_model)
        responses = { first: first, repeated: repeated, missing: missing, failed: failed,
                      malformed: malformed, unavailable: unavailable }.transform_values do |response|
          { status: response.status, body: ::JSON.parse(response.body) }
        end
        result = { responses: responses, repeat_preserved_time: repeat_preserved_time }
      when 'maintenance'
        decay = maintenance.force_decay(factor: 0.5)
        after_decay = db[:apollo_entries].order(:id).all
        invalid_factor = maintenance.force_decay(factor: -0.1)
        invalid_factor_unchanged = after_decay == db[:apollo_entries].order(:id).all
        archive = maintenance.archive_stale(days: 90)
        repeated = maintenance.archive_stale(days: 90)
        before_invalid_days = db[:apollo_entries].order(:id).all
        invalid_days = maintenance.archive_stale(days: -1)
        result = { decay: decay, after_decay: after_decay, invalid_factor: invalid_factor,
                   invalid_factor_unchanged: invalid_factor_unchanged, archive: archive, repeated: repeated,
                   invalid_days: invalid_days, invalid_days_unchanged: before_invalid_days == db[:apollo_entries].order(:id).all }
      when 'dispute'
        db[:apollo_entries].where(id: [1, 2, 3]).update(status: 'disputed')
        db[:apollo_entries].insert(attributes.merge(id: 6, content: 'kept dispute', status: 'disputed'))
        before_unknown = entry_model[6].values
        unknown = maintenance.resolve_dispute(entry_id: 6, resolution: :unexpected)
        unknown_unchanged = before_unknown == entry_model[6].values
        accepted = maintenance.resolve_dispute(entry_id: 1, resolution: :accept)
        rejected = maintenance.resolve_dispute(entry_id: 3, resolution: :reject)
        kept = maintenance.resolve_dispute(entry_id: 6, resolution: :keep)
        failed = maintenance.resolve_dispute(entry_id: 2, resolution: :reject)
        missing = maintenance.resolve_dispute(entry_id: 999, resolution: :accept)
        not_disputed = maintenance.resolve_dispute(entry_id: 4, resolution: :reject)
        repeated = maintenance.resolve_dispute(entry_id: 1, resolution: :accept)
        result = { accepted: accepted, rejected: rejected, kept: kept, failed: failed, missing: missing,
                   not_disputed: not_disputed, repeated: repeated, unknown: unknown, unknown_unchanged: unknown_unchanged }
      end
      puts "APOLLO_RESULT=#{::JSON.generate(result.merge(entries: db[:apollo_entries].order(:id).all))}"
    RUBY
  end

  def lifecycle_state(operation:, **)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, '-Ilib', '-Ispec', '-e', lifecycle_script,
      chdir:      File.expand_path('../../../../..', __dir__),
      stdin_data: JSON.generate(operation: operation)
    )
    line = stdout.lines.find { |output| output.start_with?('APOLLO_RESULT=') }
    raise "Lifecycle process failed: #{stderr}\n#{stdout}" unless status.success? && line

    JSON.parse(line.delete_prefix('APOLLO_RESULT='), symbolize_names: true)
  end

  it 'archives through HTTP with retained metadata and truthful repeat, missing, unavailable, and rollback outcomes' do
    state = lifecycle_state(operation: 'deprecate')
    responses = state[:responses]

    expect(responses[:first]).to include(status: 200, body: hash_including(success: true, updated: true, status: 'archived'))
    expect(responses[:repeated]).to include(status: 200, body: hash_including(success: true, updated: false))
    expect(state[:repeat_preserved_time]).to be true
    expect(responses[:missing]).to include(status: 404, body: hash_including(error: 'entry_not_found'))
    expect(responses[:unavailable]).to include(status: 503, body: hash_including(error: 'apollo_data_not_available'))
    expect(responses[:failed]).to include(status: 500, body: hash_including(success: false))
    expect(responses[:malformed][:status]).to eq(400)
    expect(state[:entries].first[:status]).to eq('archived')
    expect(JSON.parse(state[:entries].first[:source_context], symbolize_names: true))
      .to include(origin: 'preserve', deprecation_reason: 'Verified replacement exists.')
    expect(state[:entries][1]).to include(status: 'candidate', source_context: JSON.generate(origin: 'preserve'))
  end

  it 'multiplies active confidence without implicit archival and archives only stale, untouched entries' do
    state = lifecycle_state(operation: 'maintenance')

    expect(state[:decay]).to include(success: true, decayed: 4)
    expect(state[:after_decay].map { |entry| entry[:confidence] }).to eq([0.4, 0.4, 0.02, 0.3, 0.7])
    expect(state[:after_decay][2][:status]).to eq('candidate')
    expect(state[:invalid_factor]).to include(success: false, error: 'invalid_factor')
    expect(state[:invalid_factor_unchanged]).to be true
    expect(state[:archive]).to include(success: true, archived: 1)
    expect(state[:repeated]).to include(success: true, archived: 0)
    expect(state[:entries][2][:status]).to eq('archived')
    expect(state[:entries][3][:status]).to eq('confirmed')
    expect(state[:invalid_days]).to include(success: false, error: 'invalid_days')
    expect(state[:invalid_days_unchanged]).to be true
  end

  it 'applies the approved dispute transitions and preserves state for invalid, ineligible, or failed decisions' do
    state = lifecycle_state(operation: 'dispute')

    expect(state[:accepted]).to include(success: true, status: 'confirmed')
    expect(state[:kept]).to include(success: true, status: 'confirmed')
    expect(state[:rejected]).to include(success: true, status: 'archived')
    expect(state[:failed]).to include(success: false)
    expect(state[:missing]).to include(success: false, error: 'entry_not_found')
    expect(state[:not_disputed]).to include(success: false, error: 'entry_not_disputed')
    expect(state[:repeated]).to include(success: false, error: 'entry_not_disputed')
    expect(state[:unknown]).to include(success: false, error: 'invalid_resolution')
    expect(state[:unknown_unchanged]).to be true
    expect(state[:entries].first).to include(status: 'confirmed', confidence: 0.8)
    expect(state[:entries].first[:confirmed_at]).not_to be_nil
    expect(JSON.parse(state[:entries].first[:source_context], symbolize_names: true))
      .to include(origin: 'preserve', dispute_resolution: 'accept')
    expect(state[:entries][1]).to include(status: 'disputed', source_context: JSON.generate(origin: 'preserve'))
    expect(state[:entries][2][:status]).to eq('archived')
    expect(state[:entries][3][:status]).to eq('confirmed')
    expect(state[:entries].last[:status]).to eq('confirmed')
  end
end
