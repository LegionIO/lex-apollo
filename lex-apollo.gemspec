# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'legion/extensions/apollo/version'

Gem::Specification.new do |spec|
  spec.name          = 'lex-apollo'
  spec.version       = Legion::Extensions::Apollo::VERSION
  spec.authors       = ['Esity']
  spec.email         = ['matthewdiverson@gmail.com']
  spec.summary       = 'Shared knowledge store for GAIA cognitive mesh'
  spec.description   = 'Durable shared knowledge with vector search, concept graph, and expertise tracking'
  spec.homepage      = 'https://github.com/LegionIO/lex-apollo'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.4'

  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage

  spec.files = Dir.glob('{lib,spec}/**/*') + %w[README.md CHANGELOG.md]
  spec.require_paths = ['lib']

  spec.add_dependency 'legion-cache', '>= 1.3.11'
  spec.add_dependency 'legion-crypt', '>= 1.4.9'
  spec.add_dependency 'legion-data', '>= 1.10.18'
  spec.add_dependency 'legion-json', '>= 1.2.1'
  spec.add_dependency 'legion-llm', '>= 0.16.10'
  spec.add_dependency 'legion-logging', '>= 1.3.2'
  spec.add_dependency 'legion-settings', '>= 1.3.14'
  spec.add_dependency 'legion-transport', '>= 1.4.23'

  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_development_dependency 'rubocop'
  spec.add_development_dependency 'rubocop-legion'
  spec.add_development_dependency 'sinatra', '~> 4.0'
  spec.add_development_dependency 'sqlite3', '>= 2.0'
end
