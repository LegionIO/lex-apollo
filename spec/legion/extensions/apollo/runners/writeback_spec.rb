# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/apollo/runners/writeback'
require 'open3'
require 'rbconfig'
require 'tmpdir'

RSpec.describe Legion::Extensions::Apollo::Runners::Writeback do
  let(:provenance) do
    { space_id: 'a' * 64, provider: 'embed-provider', model: 'embed-model', instance: 'local',
      model_revision: nil, identity_source: 'instance', dimensions: 2, task: 'document',
      prefixes: { document: '', query: '' }, normalization: 'none' }
  end
  let(:payload) do
    { content: 'test content', content_type: 'observation', tags: ['test'], source_provider: 'producer',
      context: { request_id: 'request' }, source_model: 'producer-model' }
  end

  it 'forwards supplied document vectors to the store route through real isolated transport' do
    script = <<~'RUBY'
      require 'legion/settings'
      Legion::Settings.load
      require 'legion/extensions/apollo'
      Legion::Settings.loader.settings[:extensions] = { apollo: Legion::Extensions::Apollo.default_settings }
      Legion::Transport::Connection.setup
      channel = Legion::Transport::Connection.session.create_channel
      queue = Legion::Transport::CONNECTOR::Queue.new(channel, 'apollo-vectorized-writeback')
      queue.bind('legion.apollo', routing_key: 'legion.apollo.writeback.store')
      received = []
      queue.subscribe(manual_ack: false) { |_, _, body| received << Legion::JSON.load(body) }
      payload = Legion::JSON.load(STDIN.read)
      result = Legion::Extensions::Apollo::Runners::Writeback.handle_vectorize(**payload)
      Legion::Transport::Connection.shutdown
      puts "APOLLO_RESULT=#{Legion::JSON.dump({ result: result, received: received })}"
    RUBY
    input = payload.merge(identity_principal_id: 41, identity_id: nil, identity_canonical_name: 'producer@example.test',
                          embedding: [0.6, 0.8], embedding_provenance: provenance,
                          routing_key: 'legion.apollo.writeback.vectorize', exchange: 'wrong-inbound-exchange')
    Dir.mktmpdir('apollo-writeback-') do |home|
      stdout, stderr, status = Open3.capture3(
        { 'HOME' => home, 'LEGION_SETTINGS_DIRS' => home, 'LEGION_DNS_BOOTSTRAP' => 'false', 'LEGION_MODE' => 'lite' },
        RbConfig.ruby, '-I', File.expand_path('../../../../../lib', __dir__), '-e', script,
        stdin_data: Legion::JSON.dump(input), chdir: home
      )
      line = stdout.lines.find { |output| output.start_with?('APOLLO_RESULT=') }
      raise "Writeback process failed: #{stderr}\n#{stdout}" unless status.success? && line

      state = Legion::JSON.load(line.delete_prefix('APOLLO_RESULT='))
      expect(state[:result]).to include(success: true, action: 'vectorized')
      expect(state[:received]).to contain_exactly(
        hash_including(content: payload[:content], identity_principal_id: 41, identity_id: nil,
                       identity_canonical_name: 'producer@example.test', context: payload[:context],
                       embedding: [0.6, 0.8], embedding_provenance: provenance)
      )
    end
  end

  it 'raises an embedding failure rather than acknowledging the delivery' do
    error = Legion::Extensions::Apollo::Helpers::Embedding::Error
    allow(Legion::Extensions::Apollo::Runners::Embedding).to receive(:document).and_raise(error, 'invalid vector')

    expect { described_class.handle_vectorize(**payload) }.to raise_error(error, 'invalid vector')
  end

  it 'raises when publication is unchecked or rejected' do
    allow(Legion::Extensions::Apollo::Runners::Embedding).to receive(:document)
      .and_return(vector: [0.6, 0.8], provenance: provenance)
    allow(described_class).to receive(:capability_can_write?).and_return(false)
    message = instance_double(Legion::Extensions::Apollo::Transport::Messages::Writeback)
    allow(Legion::Extensions::Apollo::Transport::Messages::Writeback).to receive(:new).and_return(message)

    [nil, { accepted: false, status: :unroutable }].each do |publication_result|
      allow(message).to receive(:publish!).and_return(publication_result)

      expect { described_class.handle_vectorize(**payload) }.to raise_error(IOError)
    end
  end

  it 'raises when local ingestion rejects the vectorized payload' do
    allow(Legion::Extensions::Apollo::Runners::Embedding).to receive(:document)
      .and_return(vector: [0.6, 0.8], provenance: provenance)
    allow(described_class).to receive(:capability_can_write?).and_return(true)
    knowledge = Module.new do
      def self.handle_ingest(**)
        { success: false, error: :invalid_access_scope }
      end
    end
    stub_const('Legion::Extensions::Apollo::Runners::Knowledge', knowledge)

    expect { described_class.handle_vectorize(**payload) }.to raise_error(IOError)
  end
end
