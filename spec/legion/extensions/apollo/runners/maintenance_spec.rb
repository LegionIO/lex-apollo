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

  describe '#force_decay' do
    it 'returns a force_decay payload' do
      result = runner.force_decay(factor: 0.5)
      expect(result[:action]).to eq(:force_decay)
      expect(result[:factor]).to eq(0.5)
    end
  end

  describe '#archive_stale' do
    it 'returns an archive payload with default days' do
      result = runner.archive_stale
      expect(result[:action]).to eq(:archive_stale)
      expect(result[:days]).to eq(90)
    end
  end

  describe '#resolve_dispute' do
    it 'returns a resolve payload' do
      result = runner.resolve_dispute(entry_id: 'uuid-123', resolution: :keep)
      expect(result[:action]).to eq(:resolve_dispute)
      expect(result[:resolution]).to eq(:keep)
    end
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
                                                  .and_return(double(exclude: double(all: [])))
        allow(mock_entry_class).to receive(:where).with(status: 'confirmed')
                                                  .and_return(double(exclude: double(all: [])))
      end

      it 'returns zero promoted and scanned' do
        result = host.check_corroboration
        expect(result[:success]).to be true
        expect(result[:promoted]).to eq(0)
        expect(result[:scanned]).to eq(0)
      end
    end

    context 'when a candidate matches a confirmed entry' do
      let(:mock_entry_class) { double('ApolloEntry') }
      let(:mock_relation_class) { double('ApolloRelation') }
      let(:embedding) { Array.new(1536, 0.5) }
      let(:candidate) do
        double('candidate', id: 'c-1', content_type: 'fact', embedding: embedding,
               confidence: 0.5, update: true)
      end
      let(:confirmed_entry) do
        double('confirmed', id: 'f-1', content_type: 'fact', embedding: embedding)
      end

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
        stub_const('Legion::Data::Model::ApolloRelation', mock_relation_class)
        allow(mock_entry_class).to receive(:where).with(status: 'candidate')
                                                  .and_return(double(exclude: double(all: [candidate])))
        allow(mock_entry_class).to receive(:where).with(status: 'confirmed')
                                                  .and_return(double(exclude: double(all: [confirmed_entry])))
        allow(mock_relation_class).to receive(:create)
      end

      it 'promotes the candidate' do
        expect(candidate).to receive(:update).with(hash_including(status: 'confirmed'))
        result = host.check_corroboration
        expect(result[:promoted]).to eq(1)
        expect(result[:scanned]).to eq(1)
      end

      it 'creates a similar_to relation' do
        expect(mock_relation_class).to receive(:create).with(
          hash_including(from_entry_id: 'c-1', to_entry_id: 'f-1', relation_type: 'similar_to')
        )
        host.check_corroboration
      end
    end

    context 'when candidate and confirmed share the same source_channel' do
      let(:mock_entry_class) { double('ApolloEntry') }
      let(:mock_relation_class) { double('ApolloRelation') }
      let(:embedding) { Array.new(1536, 0.5) }
      let(:candidate) do
        double('candidate', id: 'c-1', content_type: 'fact', embedding: embedding,
               confidence: 0.5, source_provider: 'openai', source_channel: 'slack-alerts')
      end
      let(:confirmed_entry) do
        double('confirmed', id: 'f-1', content_type: 'fact', embedding: embedding,
               source_provider: 'claude', source_channel: 'slack-alerts')
      end

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
        stub_const('Legion::Data::Model::ApolloRelation', mock_relation_class)
        allow(mock_entry_class).to receive(:where).with(status: 'candidate')
                                                  .and_return(double(exclude: double(all: [candidate])))
        allow(mock_entry_class).to receive(:where).with(status: 'confirmed')
                                                  .and_return(double(exclude: double(all: [confirmed_entry])))
      end

      it 'does not promote even with different providers' do
        result = host.check_corroboration
        expect(result[:promoted]).to eq(0)
      end
    end

    context 'when candidate has different content_type than confirmed' do
      let(:mock_entry_class) { double('ApolloEntry') }
      let(:embedding) { Array.new(1536, 0.5) }
      let(:candidate) do
        double('candidate', id: 'c-1', content_type: 'fact', embedding: embedding, confidence: 0.5)
      end
      let(:confirmed_entry) do
        double('confirmed', id: 'f-1', content_type: 'concept', embedding: embedding)
      end

      before do
        stub_const('Legion::Data::Model::ApolloEntry', mock_entry_class)
        allow(mock_entry_class).to receive(:where).with(status: 'candidate')
                                                  .and_return(double(exclude: double(all: [candidate])))
        allow(mock_entry_class).to receive(:where).with(status: 'confirmed')
                                                  .and_return(double(exclude: double(all: [confirmed_entry])))
      end

      it 'does not promote' do
        result = host.check_corroboration
        expect(result[:promoted]).to eq(0)
      end
    end
  end
end
