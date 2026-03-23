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
        expect(result).to eq(Array.new(1536, 0.0))
        expect(result.size).to eq(1536)
      end
    end

    context 'when Legion::LLM is defined but not started' do
      before do
        stub_const('Legion::LLM', Module.new { def self.started? = false })
      end

      it 'returns a zero vector' do
        result = described_class.generate(text: 'hello world')
        expect(result).to eq(Array.new(1536, 0.0))
      end
    end

    context 'when Legion::LLM is available and started' do
      let(:mock_embedding) { Array.new(1536) { rand(-1.0..1.0) } }

      before do
        llm = Module.new do
          define_method(:started?) { true }
          define_method(:embed) { |_text:| nil }
          extend self
        end
        stub_const('Legion::LLM', llm)
        allow(Legion::LLM).to receive(:embed).and_return(mock_embedding)
      end

      it 'returns the embedding from LLM' do
        result = described_class.generate(text: 'hello world')
        expect(result).to eq(mock_embedding)
        expect(Legion::LLM).to have_received(:embed).with(text: 'hello world')
      end
    end

    context 'when Legion::LLM returns a short embedding' do
      before do
        llm = Module.new do
          define_method(:started?) { true }
          define_method(:embed) { |_text:| nil }
          extend self
        end
        stub_const('Legion::LLM', llm)
        allow(Legion::LLM).to receive(:embed).and_return([0.1, 0.2])
      end

      it 'accepts the embedding and updates dimension' do
        result = described_class.generate(text: 'hello world')
        expect(result).to eq([0.1, 0.2])
        expect(described_class.dimension).to eq(2)
      end
    end

    context 'when Legion::LLM returns nil' do
      before do
        llm = Module.new do
          define_method(:started?) { true }
          define_method(:embed) { |_text:| nil }
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
end
