# frozen_string_literal: true

require 'spec_helper'

$LOADED_FEATURES << 'legion/extensions/actors/subscription' unless $LOADED_FEATURES.include?('legion/extensions/actors/subscription')
require 'legion/extensions/apollo/actors/ingest'

RSpec.describe Legion::Extensions::Apollo::Actor::Ingest do
  subject(:actor) { described_class.new }

  let(:payload) { { content: 'remote fact', content_type: 'fact' } }

  it 'uses explicit null ownership for an unidentified producer rather than the service process identity' do
    allow_any_instance_of(described_class.superclass).to receive(:process_message).and_return(payload)

    expect(actor.process_message('payload', nil, nil)).to eq(
      **payload, identity_principal_id: nil, identity_id: nil, identity_canonical_name: nil
    )
  end

  it 'preserves producer identity and explicit null identity fields after superclass decoding' do
    identity = { identity_principal_id: 31, identity_id: nil, identity_canonical_name: 'producer@example.test' }
    allow_any_instance_of(described_class.superclass).to receive(:process_message).and_return(payload.merge(identity))

    expect(actor.process_message('payload', nil, nil)).to include(identity)
  end
end
