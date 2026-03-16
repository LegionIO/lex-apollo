# frozen_string_literal: true

require 'bundler/setup'

module Legion
  module Logging
    def self.debug(_msg); end
    def self.info(_msg); end
    def self.warn(_msg); end
    def self.error(_msg); end
  end
end

# Sequel is a runtime dependency via legion-data; stub for specs
unless defined?(Sequel)
  module Sequel
    class Error < StandardError; end

    def self.pg_array(arr) = arr
    def self.lit(str) = str
    Expr = Struct.new(:value) { def +(other) = "#{value} + #{other}" }
    def self.expr(sym) = Expr.new(sym)
  end
end

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
