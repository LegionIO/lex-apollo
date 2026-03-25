# frozen_string_literal: true

module Legion
  module Extensions
    module Apollo
      module Helpers
        module Embedding
          DEFAULT_DIMENSION = 1024

          LOCAL_EMBEDDING_MODELS = %w[mxbai-embed-large bge-large snowflake-arctic-embed].freeze

          module_function

          def generate(text:, **)
            unless defined?(Legion::LLM) && Legion::LLM.started?
              Legion::Logging.debug('[apollo] embedding fallback: LLM not started') if defined?(Legion::Logging)
              return zero_vector
            end

            local_model = detect_local_model
            vector = if local_model
                       ollama_embed(text, local_model)
                     else
                       opts = cloud_embedding_opts
                       result = Legion::LLM.embed(text, **opts)
                       result.is_a?(Hash) ? result[:vector] : result
                     end

            if vector.is_a?(Array) && vector.any?
              @dimension = vector.size
              vector
            else
              Legion::Logging.warn('[apollo] embedding fallback: LLM returned no vector') if defined?(Legion::Logging)
              zero_vector
            end
          end

          def dimension
            @dimension || configured_dimension
          end

          def configured_dimension
            return DEFAULT_DIMENSION unless defined?(Legion::Settings) && !Legion::Settings[:apollo].nil?

            Legion::Settings[:apollo].dig(:embedding, :dimension) || DEFAULT_DIMENSION
          rescue StandardError
            DEFAULT_DIMENSION
          end

          def ollama_embed(text, model)
            require 'faraday'
            base_url = ollama_base_url
            Legion::Logging.debug("[apollo] embedding via local Ollama: #{model}") if defined?(Legion::Logging)
            conn = Faraday.new(url: base_url) { |f| f.options.timeout = 10 }
            response = conn.post('/api/embed', { model: model, input: text }.to_json,
                                 'Content-Type' => 'application/json')
            return nil unless response.success?

            parsed = ::JSON.parse(response.body)
            parsed['embeddings']&.first
          rescue StandardError => e
            Legion::Logging.warn("[apollo] local Ollama embed failed: #{e.message}") if defined?(Legion::Logging)
            nil
          end

          def ollama_base_url
            return 'http://localhost:11434' unless defined?(Legion::Settings)

            Legion::Settings[:llm].dig(:providers, :ollama, :base_url) || 'http://localhost:11434'
          rescue StandardError
            'http://localhost:11434'
          end

          def cloud_embedding_opts
            return {} unless defined?(Legion::Settings) && !Legion::Settings[:apollo].nil?

            embedding = Legion::Settings[:apollo][:embedding] || {}
            opts = {}
            opts[:provider] = embedding[:provider].to_sym if embedding[:provider]
            opts[:model]    = embedding[:model] if embedding[:model]
            opts
          rescue StandardError
            {}
          end

          def detect_local_model
            return nil unless defined?(Legion::LLM::Discovery::Ollama)

            LOCAL_EMBEDDING_MODELS.find do |m|
              Legion::LLM::Discovery::Ollama.model_available?(m) ||
                Legion::LLM::Discovery::Ollama.model_available?("#{m}:latest")
            end
          rescue StandardError
            nil
          end

          def zero_vector
            Array.new(dimension, 0.0)
          end
        end
      end
    end
  end
end
