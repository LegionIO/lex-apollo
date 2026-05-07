# frozen_string_literal: true

# Stub Sinatra before requiring api.rb so the guard `unless defined?(Sinatra)` fires.
# This avoids a LoadError when sinatra is not in the bundle.
unless defined?(Sinatra)
  module Sinatra
    class Base
      class << self
        def set(*, **); end
        def before(*, &); end
        def helpers(*, &); end
        def get(*, &); end
        def post(*, &); end
        def put(*, &); end
        def delete(*, &); end
      end
    end
  end
end

require 'spec_helper'
require 'legion/extensions/apollo/api'

RSpec.describe Legion::Extensions::Apollo::Api do
  it 'is defined as a Sinatra app' do
    expect(described_class.superclass).to eq(Sinatra::Base)
  end

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
end
