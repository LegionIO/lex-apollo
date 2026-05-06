# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/helpers/capability'

unless defined?(Legion::LLM)
  module Legion
    module LLM
      def self.started? = false
    end
  end
end

RSpec.describe Legion::Extensions::Apollo::Helpers::Capability do
  before do
    Legion::Settings[:extensions][:apollo] = Legion::Extensions::Apollo.default_settings
    described_class.instance_variable_set(:@apollo_write_privilege, nil)
  end

  describe '.can_embed?' do
    it 'returns true when LLM is started and Ollama has a model' do
      allow(Legion::LLM).to receive(:started?).and_return(true)
      allow(described_class).to receive(:ollama_embedding_available?).and_return(true)
      expect(described_class.can_embed?).to be true
    end

    it 'returns false when LLM is not started' do
      allow(Legion::LLM).to receive(:started?).and_return(false) if defined?(Legion::LLM)
      expect(described_class.can_embed?).to be false
    end
  end

  describe '.can_write?' do
    it 'returns false when apollo_write setting is false' do
      described_class.settings[:data][:apollo_write] = false
      expect(described_class.can_write?).to be false
    end

    it 'returns false when Data is not connected' do
      described_class.settings[:data][:apollo_write] = true
      allow(Legion::Data).to receive(:connected?).and_return(false) if defined?(Legion::Data)
      expect(described_class.can_write?).to be false
    end
  end

  describe '.apollo_write_enabled?' do
    it 'reads from settings' do
      described_class.settings[:data][:apollo_write] = true
      expect(described_class.apollo_write_enabled?).to be true
    end

    it 'defaults to false' do
      expect(described_class.apollo_write_enabled?).to be false
    end
  end
end
