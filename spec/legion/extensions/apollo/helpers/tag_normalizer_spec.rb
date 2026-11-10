# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/helpers/tag_normalizer'

RSpec.describe Legion::Extensions::Apollo::Helpers::TagNormalizer do
  let(:host) { Object.new.extend(described_class) }

  describe 'tag normalization' do
    it 'lowercases tags' do
      expect(host.send(:tag_normalize, raw: 'RabbitMQ')).to eq('rabbitmq')
    end

    it 'strips leading/trailing whitespace' do
      expect(host.send(:tag_normalize, raw: '  hello  ')).to eq('hello')
    end

    it 'replaces spaces with hyphens' do
      expect(host.send(:tag_normalize, raw: 'message broker')).to eq('message-broker')
    end

    it 'strips special characters except hyphens' do
      expect(host.send(:tag_normalize, raw: 'c#')).to eq('csharp')
      expect(host.send(:tag_normalize, raw: 'hello!')).to eq('hello')
      expect(host.send(:tag_normalize, raw: 'key=value')).to eq('keyvalue')
    end

    it 'collapses multiple hyphens' do
      expect(host.send(:tag_normalize, raw: 'a--b---c')).to eq('a-b-c')
    end

    it 'applies known aliases' do
      expect(host.send(:tag_normalize, raw: 'C++')).to eq('cplusplus')
      expect(host.send(:tag_normalize, raw: '.NET')).to eq('dotnet')
      expect(host.send(:tag_normalize, raw: 'node.js')).to eq('nodejs')
    end

    it 'returns nil for empty results' do
      expect(host.send(:tag_normalize, raw: '!!!')).to be_nil
      expect(host.send(:tag_normalize, raw: '')).to be_nil
    end
  end

  describe 'tag collection normalization' do
    it 'normalizes, deduplicates, and caps at max' do
      tags = %w[RabbitMQ rabbitmq AMQP message-broker extra-tag sixth-tag]
      result = host.send(:tag_normalize_all, tags: tags, max: 5)
      expect(result).to eq(%w[rabbitmq amqp message-broker extra-tag sixth-tag])
    end

    it 'filters out nil results' do
      expect(host.send(:tag_normalize_all, tags: ['!!!', 'valid'])).to eq(['valid'])
    end

    it 'handles nil input' do
      expect(host.send(:tag_normalize_all, tags: nil)).to eq([])
    end

    it 'defaults max to 5' do
      tags = %w[a b c d e f g]
      expect(host.send(:tag_normalize_all, tags: tags).length).to eq(5)
    end
  end
end
