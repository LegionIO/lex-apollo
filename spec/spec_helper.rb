# frozen_string_literal: true

require 'bundler/setup'
require 'legion/logging'
require 'legion/settings'
require 'legion/cache/helper'
require 'legion/crypt/helper'
require 'legion/data/helper'
require 'legion/json/helper'
require 'legion/transport'

# Sequel is a runtime dependency via legion-data; stub for specs
unless defined?(Sequel)
  module Sequel
    class Error < StandardError; end

    def self.pg_array(arr) = arr
    def self.lit(str, *) = str
    def self.desc(sym) = sym
    Expr = Struct.new(:value) do
      def +(other) = "#{value} + #{other}"
      def *(other) = "#{value} * #{other}"
    end
    def self.expr(sym) = Expr.new(sym)
    def self.[](sym) = Expr.new(sym)
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
