# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/helpers/tag_normalizer'

RSpec.describe Legion::Extensions::Apollo::Helpers::TagNormalizer do
  describe '.normalize' do
    it 'lowercases tags' do
      expect(described_class.normalize('RabbitMQ')).to eq('rabbitmq')
    end

    it 'strips leading/trailing whitespace' do
      expect(described_class.normalize('  hello  ')).to eq('hello')
    end

    it 'replaces spaces with hyphens' do
      expect(described_class.normalize('message broker')).to eq('message-broker')
    end

    it 'strips special characters except hyphens' do
      expect(described_class.normalize('c#')).to eq('csharp')
      expect(described_class.normalize('hello!')).to eq('hello')
      expect(described_class.normalize('key=value')).to eq('keyvalue')
    end

    it 'collapses multiple hyphens' do
      expect(described_class.normalize('a--b---c')).to eq('a-b-c')
    end

    it 'applies known aliases' do
      expect(described_class.normalize('C++')).to eq('cplusplus')
      expect(described_class.normalize('.NET')).to eq('dotnet')
      expect(described_class.normalize('node.js')).to eq('nodejs')
    end

    it 'returns nil for empty results' do
      expect(described_class.normalize('!!!')).to be_nil
      expect(described_class.normalize('')).to be_nil
    end
  end

  describe '.normalize_all' do
    it 'normalizes, deduplicates, and caps at max' do
      tags = %w[RabbitMQ rabbitmq AMQP message-broker extra-tag sixth-tag]
      result = described_class.normalize_all(tags, max: 5)
      expect(result).to eq(%w[rabbitmq amqp message-broker extra-tag sixth-tag])
    end

    it 'filters out nil results' do
      expect(described_class.normalize_all(['!!!', 'valid'])).to eq(['valid'])
    end

    it 'handles nil input' do
      expect(described_class.normalize_all(nil)).to eq([])
    end

    it 'defaults max to 5' do
      tags = %w[a b c d e f g]
      expect(described_class.normalize_all(tags).length).to eq(5)
    end
  end
end
