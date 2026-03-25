# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/helpers/embedding'

RSpec.describe Legion::Extensions::Apollo::Helpers::Embedding do
  describe '.generate' do
    context 'when Legion::LLM is not defined' do
      before do
        hide_const('Legion::LLM') if defined?(Legion::LLM)
      end

      it 'returns a zero vector of the correct dimension' do
        result = described_class.generate(text: 'hello world')
        expect(result).to eq(Array.new(1024, 0.0))
        expect(result.size).to eq(1024)
      end
    end

    context 'when Legion::LLM is defined but not started' do
      before do
        stub_const('Legion::LLM', Module.new { def self.started? = false })
      end

      it 'returns a zero vector' do
        result = described_class.generate(text: 'hello world')
        expect(result).to eq(Array.new(1024, 0.0))
      end
    end

    context 'when Legion::LLM is available and started' do
      let(:mock_vector) { Array.new(1024) { rand(-1.0..1.0) } }

      before do
        llm = Module.new do
          define_method(:started?) { true }
          define_method(:embed) { |_text, **| nil }
          extend self
        end
        stub_const('Legion::LLM', llm)
        allow(Legion::LLM).to receive(:embed).and_return({ vector: mock_vector, model: 'text-embedding-3-small' })
      end

      it 'returns the vector from the LLM response hash' do
        result = described_class.generate(text: 'hello world')
        expect(result).to eq(mock_vector)
        expect(Legion::LLM).to have_received(:embed).with('hello world', **{})
      end
    end

    context 'when Legion::LLM returns a short embedding' do
      before do
        llm = Module.new do
          define_method(:started?) { true }
          define_method(:embed) { |_text, **| nil }
          extend self
        end
        stub_const('Legion::LLM', llm)
        allow(Legion::LLM).to receive(:embed).and_return({ vector: [0.1, 0.2], model: 'test' })
      end

      it 'accepts the embedding and updates dimension' do
        result = described_class.generate(text: 'hello world')
        expect(result).to eq([0.1, 0.2])
        expect(described_class.dimension).to eq(2)
      end
    end

    context 'when Legion::LLM returns nil vector' do
      before do
        llm = Module.new do
          define_method(:started?) { true }
          define_method(:embed) { |_text, **| nil }
          extend self
        end
        stub_const('Legion::LLM', llm)
        allow(Legion::LLM).to receive(:embed).and_return({ vector: nil, model: 'test', error: 'failed' })
      end

      it 'returns a zero vector as fallback' do
        result = described_class.generate(text: 'hello world')
        expect(result).to be_an(Array)
        expect(result.all?(&:zero?)).to be true
      end
    end

    context 'when Legion::LLM returns nil' do
      before do
        llm = Module.new do
          define_method(:started?) { true }
          define_method(:embed) { |_text, **| nil }
          extend self
        end
        stub_const('Legion::LLM', llm)
        allow(Legion::LLM).to receive(:embed).and_return(nil)
      end

      it 'returns a zero vector as fallback' do
        result = described_class.generate(text: 'hello world')
        expect(result).to be_an(Array)
        expect(result.all?(&:zero?)).to be true
      end
    end
  end

  describe '.configured_dimension' do
    context 'when Settings has apollo.embedding.dimension' do
      before do
        stub_const('Legion::Settings', { apollo: { embedding: { dimension: 768 } } })
      end

      it 'returns the configured dimension' do
        expect(described_class.configured_dimension).to eq(768)
      end
    end

    context 'when Settings has no apollo key' do
      before do
        stub_const('Legion::Settings', { apollo: nil })
      end

      it 'returns the default dimension' do
        expect(described_class.configured_dimension).to eq(1024)
      end
    end
  end
end
