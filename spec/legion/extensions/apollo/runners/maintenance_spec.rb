# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/helpers/confidence'
require 'legion/extensions/apollo/helpers/similarity'
require 'legion/extensions/apollo/runners/maintenance'

RSpec.describe Legion::Extensions::Apollo::Runners::Maintenance do
  let(:runner) do
    obj = Object.new
    obj.extend(described_class)
    obj
  end

  it 'retains client action envelopes without claiming completed service mutations when data is unavailable' do
    results = [runner.force_decay(factor: 0.5), runner.archive_stale(days: 90),
               runner.resolve_dispute(entry_id: 'uuid-123', resolution: :keep)]

    expect(results.map { |result| result[:action] }).to eq(%i[force_decay archive_stale resolve_dispute])
    expect(results).to all(satisfy { |result| !result.key?(:success) })
  end

  describe '#run_decay_cycle' do
    let(:host) { Object.new.extend(described_class) }

    context 'when Legion::Data is not available' do
      before { hide_const('Legion::Data') if defined?(Legion::Data) }

      it 'returns zero counts' do
        result = host.run_decay_cycle
        expect(result[:decayed]).to eq(0)
        expect(result[:archived]).to eq(0)
      end
    end

    context 'with SQLite records spanning a batch boundary' do
      let(:db) { Sequel.sqlite }

      before do
        db.create_table(:apollo_entries) do
          primary_key :id
          String :status
          Float :confidence
          DateTime :created_at
          DateTime :updated_at
        end
        allow(Legion::Data).to receive(:connection).and_return(db)
      end

      after { db.disconnect }

      it 'decays all eligible rows without skipping records as archived rows leave the batch scope' do
        old = Time.now - (30 * 86_400)
        501.times { db[:apollo_entries].insert(status: 'candidate', confidence: 0.01, created_at: old) }
        retained = db[:apollo_entries].insert(status: 'confirmed', confidence: 1.0, created_at: old)
        young = db[:apollo_entries].insert(status: 'candidate', confidence: 0.01, created_at: Time.now)

        expect(host.run_decay_cycle(alpha: 0.3, min_confidence: 0.05)).to include(decayed: 502, archived: 501)
        expect(db[:apollo_entries].where(status: 'archived').count).to eq(501)
        expect(db[:apollo_entries][id: retained][:confidence]).to be_between(0.9, 1.0).exclusive
        expect(db[:apollo_entries][id: young]).to include(status: 'candidate', confidence: 0.01)
      end
    end
  end

  describe '#check_corroboration' do
    let(:host) { Object.new.extend(described_class) }

    context 'when Apollo data is not available' do
      before { hide_const('Legion::Data::Model::ApolloEntry') if defined?(Legion::Data::Model::ApolloEntry) }

      it 'returns a structured error' do
        result = host.check_corroboration
        expect(result[:success]).to be false
        expect(result[:error]).to eq('apollo_data_not_available')
      end
    end

    context 'when relation persistence is unavailable' do
      let(:mock_entry_class) { double('ApolloEntry') }

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
        hide_const('Legion::Data::Model::ApolloRelation') if defined?(Legion::Data::Model::ApolloRelation)
        hide_const('Legion::Data::Model::Apollo::Relation') if defined?(Legion::Data::Model::Apollo::Relation)
      end

      it 'fails before scanning or promoting candidates' do
        expect(mock_entry_class).not_to receive(:where)

        expect(host.check_corroboration).to include(success: false, error: 'apollo_data_not_available')
      end
    end
  end
end
