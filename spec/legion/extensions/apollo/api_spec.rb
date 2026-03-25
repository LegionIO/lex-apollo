# frozen_string_literal: true

# Stub Sinatra before requiring api.rb so the guard `unless defined?(Sinatra)` fires.
# This avoids a LoadError when sinatra is not in the bundle.
unless defined?(Sinatra)
  module Sinatra
    class Base
      class << self
        def set(*, **); end
        def before(*, &); end
        def helpers(*, &); end
        def get(*, &); end
        def post(*, &); end
        def put(*, &); end
        def delete(*, &); end
      end
    end
  end
end

require 'spec_helper'
require 'legion/extensions/apollo/api'

RSpec.describe Legion::Extensions::Apollo::Api do
  it 'is defined as a Sinatra app' do
    expect(described_class.superclass).to eq(Sinatra::Base)
  end
end
