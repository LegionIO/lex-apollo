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
      allow(Legion::Settings).to receive(:dig).with(:data, :apollo_write).and_return(false)
      expect(described_class.can_write?).to be false
    end

    it 'returns false when Data is not connected' do
      allow(Legion::Settings).to receive(:dig).with(:data, :apollo_write).and_return(true)
      allow(Legion::Data).to receive(:connected?).and_return(false) if defined?(Legion::Data)
      expect(described_class.can_write?).to be false
    end
  end

  describe '.apollo_write_enabled?' do
    it 'reads from settings' do
      allow(Legion::Settings).to receive(:dig).with(:data, :apollo_write).and_return(true)
      expect(described_class.apollo_write_enabled?).to be true
    end

    it 'defaults to false' do
      allow(Legion::Settings).to receive(:dig).with(:data, :apollo_write).and_return(nil)
      expect(described_class.apollo_write_enabled?).to be false
    end
  end
end
