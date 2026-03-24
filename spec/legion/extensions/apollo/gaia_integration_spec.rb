# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/gaia_integration'

RSpec.describe Legion::Extensions::Apollo::GaiaIntegration do
  describe '.publishable?' do
    it 'returns true when above thresholds' do
      expect(described_class.publishable?({ confidence: 0.8, novelty: 0.5 })).to be true
    end

    it 'returns false when below confidence' do
      expect(described_class.publishable?({ confidence: 0.3, novelty: 0.5 })).to be false
    end

    it 'returns false when below novelty' do
      expect(described_class.publishable?({ confidence: 0.8, novelty: 0.1 })).to be false
    end

    it 'returns false with empty hash' do
      expect(described_class.publishable?({})).to be false
    end
  end

  describe '.handle_mesh_departure' do
    it 'returns nil when ApolloExpertise unavailable' do
      expect(described_class.handle_mesh_departure(agent_id: 'test')).to be_nil
    end
  end

  describe '.publish_insight' do
    it 'returns nil when not publishable' do
      expect(described_class.publish_insight({ confidence: 0.1, novelty: 0.1 }, agent_id: 'test')).to be_nil
    end

    it 'calls client when publishable and client available' do
      client_double = instance_double(Legion::Extensions::Apollo::Client)
      allow(Legion::Extensions::Apollo::Client).to receive(:new).and_return(client_double)
      allow(client_double).to receive(:store_knowledge).and_return({ success: true })

      result = described_class.publish_insight(
        { confidence: 0.9, novelty: 0.5, content: 'test insight', domain: 'fact' },
        agent_id: 'test-agent'
      )
      expect(result).to eq({ success: true })
    end
  end

  describe 'entity watchdog phase handler' do
    it 'detects entities from tick results' do
      require 'legion/extensions/apollo/helpers/entity_watchdog'
      tick_results = { content: 'Jane Doe deployed to https://api.example.com', tick_id: 'tick-1' }
      entities = Legion::Extensions::Apollo::Helpers::EntityWatchdog.detect_entities(text: tick_results[:content])
      expect(entities.size).to be >= 2
    end

    it 'links or creates entities from tick results' do
      require 'legion/extensions/apollo/helpers/entity_watchdog'
      tick_results = { content: 'Jane Doe at LegionIO/lex-mesh', tick_id: 'tick-2' }
      entities = Legion::Extensions::Apollo::Helpers::EntityWatchdog.detect_entities(text: tick_results[:content])
      result = Legion::Extensions::Apollo::Helpers::EntityWatchdog.link_or_create(
        entities: entities, source_context: tick_results[:tick_id]
      )
      expect(result[:success]).to be true
    end

    it 'entry point documents entity watchdog actor' do
      entry_point = File.read(File.expand_path('../../../../lib/legion/extensions/apollo.rb', __dir__))
      expect(entry_point).to include('Entity watchdog runs as Actor::EntityWatchdog')
    end
  end
end
