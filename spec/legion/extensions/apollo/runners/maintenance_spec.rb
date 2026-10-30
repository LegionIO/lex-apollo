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

    context 'when data is available' do
      let(:mock_conn) { double('connection') }
      let(:mock_dataset) { double('dataset') }

      before do
        data_mod = Module.new do
          def self.connection; end

          def self.respond_to?(method, *args)
            method == :connection || super
          end
        end
        stub_const('Legion::Data', data_mod)
        allow(Legion::Data).to receive(:connection).and_return(mock_conn)
        allow(mock_conn).to receive(:[]).with(:apollo_entries).and_return(mock_dataset)
        allow(mock_dataset).to receive(:exclude).and_return(mock_dataset)
        allow(mock_dataset).to receive(:where).and_return(mock_dataset)
        allow(mock_dataset).to receive(:update).and_return(5)
      end

      it 'returns alpha in result hash' do
        result = host.run_decay_cycle
        expect(result[:alpha]).to eq(0.05)
        expect(result).not_to have_key(:rate)
      end

      it 'returns decayed and archived counts' do
        result = host.run_decay_cycle
        expect(result[:decayed]).to eq(5)
        expect(result[:archived]).to eq(5)
      end

      it 'accepts custom alpha parameter' do
        result = host.run_decay_cycle(alpha: 0.3)
        expect(result[:alpha]).to eq(0.3)
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

    context 'when no candidates exist' do
      let(:mock_entry_class) { double('ApolloEntry') }

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
        allow(mock_entry_class).to receive(:where).with(status: 'candidate')
                                                  .and_return(double(exclude: double(limit: double(all: []))))
      end

      it 'returns zero promoted and scanned' do
        result = host.check_corroboration
        expect(result[:success]).to be true
        expect(result[:promoted]).to eq(0)
        expect(result[:scanned]).to eq(0)
      end
    end
  end
end
