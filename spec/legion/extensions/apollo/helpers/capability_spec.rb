# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/helpers/capability'

RSpec.describe Legion::Extensions::Apollo::Helpers::Capability do
  let(:host) { Object.new.extend(described_class) }
  let(:settings) { Legion::Extensions::Apollo.default_settings }

  before do
    allow(host).to receive(:settings).and_return(settings)
  end

  describe '.can_embed?' do
    it 'returns true when LLM is started and SSOT has an embedding lane' do
      allow(Legion::LLM).to receive(:started?).and_return(true)
      allow(Legion::LLM).to receive(:can_embed?).and_return(true)
      expect(host.send(:capability_can_embed?)).to be true
    end

    it 'returns false when LLM is not started' do
      allow(Legion::LLM).to receive(:started?).and_return(false)
      expect(host.send(:capability_can_embed?)).to be false
    end
  end

  it 'returns false when the running LLM has no embedding lane' do
    allow(Legion::LLM).to receive(:started?).and_return(true)
    allow(Legion::LLM).to receive(:can_embed?).and_return(false)
    expect(host.send(:capability_can_embed?)).to be false
  end

  describe '.can_write?' do
    it 'returns false when apollo_write setting is false' do
      settings[:data][:apollo_write] = false
      expect(host.send(:capability_can_write?)).to be false
    end

    it 'returns false when the native Data write capability is unavailable' do
      settings[:data][:apollo_write] = true
      allow(Legion::Data).to receive(:can_write?).with(:apollo_entries).and_return(false)
      expect(host.send(:capability_can_write?)).to be false
    end

    it 'allows an adapter-approved SQLite writer without issuing PostgreSQL privilege SQL' do
      settings[:data][:apollo_write] = true
      allow(Legion::Data).to receive(:can_write?).with(:apollo_entries).and_return(true)
      expect(Legion::Data).not_to receive(:connection)

      expect(host.send(:capability_can_write?)).to be true
    end
  end
end
