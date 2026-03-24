# frozen_string_literal: true

require 'spec_helper'

unless defined?(Legion::Extensions::Actors::Every)
  module Legion
    module Extensions
      module Actors
        class Every
          def initialize(**_opts); end
        end
      end
    end
  end
end
$LOADED_FEATURES << 'legion/extensions/actors/every' unless $LOADED_FEATURES.include?('legion/extensions/actors/every')

require 'legion/extensions/apollo/runners/knowledge'
require 'legion/extensions/apollo/runners/entity_extractor'
require 'legion/extensions/apollo/actors/entity_watchdog'

RSpec.describe Legion::Extensions::Apollo::Actor::EntityWatchdog do
  subject(:actor) { described_class.allocate }

  describe 'actor configuration' do
    it 'uses self.class as runner_class for self-contained dispatch' do
      expect(actor.runner_class).to eq(described_class)
    end

    it 'runs scan_and_ingest function' do
      expect(actor.runner_function).to eq('scan_and_ingest')
    end

    it 'runs every 120 seconds' do
      expect(actor.time).to eq(120)
    end

    it 'does not run immediately' do
      expect(actor.run_now?).to be false
    end

    it 'does not use the runner framework (calls manual directly)' do
      expect(actor.use_runner?).to be false
    end

    it 'does not generate tasks' do
      expect(actor.generate_task?).to be false
    end
  end

  describe '#scan_and_ingest' do
    let(:entities) { [{ name: 'lex-synapse', type: 'repository', confidence: 0.95 }] }
    let(:no_match) { { success: true, entries: [], count: 0 } }

    before do
      allow(actor).to receive(:recent_task_log_texts).and_return(['deploying lex-synapse to nomad'])
      allow(actor).to receive(:extract_entities).with(text:           'deploying lex-synapse to nomad',
                                                      entity_types:   anything,
                                                      min_confidence: anything)
                                                .and_return({ success: true, entities: entities, source: :llm })
      allow(actor).to receive(:retrieve_relevant).and_return(no_match)
      allow(actor).to receive(:publish_entity_ingest)
    end

    it 'calls publish_entity_ingest for new entities' do
      actor.scan_and_ingest
      expect(actor).to have_received(:publish_entity_ingest).once
    end

    context 'when entity already exists in Apollo (high similarity)' do
      let(:existing_match) do
        { success: true, entries: [{ id: 42, content: 'lex-synapse', distance: 0.02 }], count: 1 }
      end

      before { allow(actor).to receive(:retrieve_relevant).and_return(existing_match) }

      it 'does not publish for duplicate entities' do
        actor.scan_and_ingest
        expect(actor).not_to have_received(:publish_entity_ingest)
      end
    end

    context 'when LLM extraction returns nothing' do
      before do
        allow(actor).to receive(:extract_entities).and_return({ success: true, entities: [], source: :unavailable })
      end

      it 'does not publish anything' do
        actor.scan_and_ingest
        expect(actor).not_to have_received(:publish_entity_ingest)
      end
    end

    context 'when data layer is unavailable' do
      before { allow(actor).to receive(:recent_task_log_texts).and_return([]) }

      it 'returns early without calling extract_entities' do
        expect(actor).not_to receive(:extract_entities)
        actor.scan_and_ingest
      end
    end
  end

  describe '#entity_types' do
    it 'returns the default list when settings are absent' do
      expect(actor.entity_types).to eq(%w[person service repository concept])
    end
  end

  describe '#dedup_similarity_threshold' do
    it 'returns a float between 0 and 1' do
      threshold = actor.dedup_similarity_threshold
      expect(threshold).to be_a(Float)
      expect(threshold).to be_between(0.0, 1.0)
    end
  end

  describe '#recent_task_log_texts' do
    context 'when legion-data is not available' do
      before { hide_const('Legion::Data') if defined?(Legion::Data) }

      it 'returns an empty array' do
        expect(actor.recent_task_log_texts).to eq([])
      end
    end
  end
end
