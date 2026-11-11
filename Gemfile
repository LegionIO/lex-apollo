# frozen_string_literal: true

source 'https://rubygems.org'
gemspec

gem 'rubocop-legion'

# PR checks place the exact companion revisions here before Bundler runs.
%w[legion-data legion-llm].each do |name|
  dependency_path = File.expand_path("tmp/ci-dependencies/#{name}", __dir__)
  gem name, path: dependency_path if Dir.exist?(dependency_path)
end
