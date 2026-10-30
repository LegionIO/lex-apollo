# frozen_string_literal: true

require 'bundler/setup'
require 'legion/logging'
require 'legion/settings'
require 'legion/cache/helper'
require 'legion/crypt/helper'
require 'legion/data/helper'
require 'legion/json/helper'
require 'legion/transport'

require 'sequel'
require 'sequel/extensions/pg_array'
require 'digest'

module ApolloSpecEmbedding
  def self.result(vector: [1.0, 0.0], task: :document, model: 'test', provider: 'test', instance: 'test', **)
    provenance = {
      space_id: Digest::SHA256.hexdigest([provider, model, instance, vector.length].join(':')),
      provider: provider, model: model, instance: instance, model_revision: nil, identity_source: 'instance',
      dimensions: vector.length, task: task.to_s, prefixes: { document: '', query: '' }, normalization: 'none'
    }
    { vector: vector, model: model, provider: provider, instance: instance,
      dimensions: vector.length, tokens: 0, embedding_provenance: provenance }
  end
end

module Legion
  module Extensions
    module Helpers
      module Lex
        include Legion::Logging::Helper
        include Legion::Settings::Helper
        include Legion::Cache::Helper
        include Legion::Crypt::Helper
        include Legion::Data::Helper
        include Legion::JSON::Helper
        include Legion::Transport::Helper
      end
    end

    module Actors
      class Every
        include Helpers::Lex
      end

      class Subscription
        include Helpers::Lex
      end
    end
  end
end

require 'legion/extensions/apollo'

Legion::Settings[:extensions][:apollo] = Legion::Extensions::Apollo.default_settings

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
