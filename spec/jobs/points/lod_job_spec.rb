# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Points::LodJob, type: :job do
  let(:user) { create(:user) }

  before do
    allow(DawarichSettings).to receive(:points_lod_enabled?).and_return(true)
    Sidekiq.redis { |redis| redis.del(described_class.lock_key(user.id)) }
  end

  it 'runs Points::Lod::Tiering for the user' do
    tiering = instance_double(Points::Lod::Tiering, call: nil)
    allow(Points::Lod::Tiering).to receive(:new).with(user.id, full: false).and_return(tiering)

    described_class.perform_now(user.id)

    expect(tiering).to have_received(:call)
  end

  it 'does nothing when the feature flag is off' do
    allow(DawarichSettings).to receive(:points_lod_enabled?).and_return(false)

    expect(Points::Lod::Tiering).not_to receive(:new)

    described_class.perform_now(user.id)
  end

  it 'skips the run while another run for the same user already holds the lock' do
    Sidekiq.redis { |redis| redis.set(described_class.lock_key(user.id), 1, nx: true, ex: 60) }

    expect(Points::Lod::Tiering).not_to receive(:new)

    described_class.perform_now(user.id)
  end

  it 'releases the lock after a run so a later call is not blocked' do
    tiering = instance_double(Points::Lod::Tiering, call: nil)
    allow(Points::Lod::Tiering).to receive(:new).and_return(tiering)

    described_class.perform_now(user.id)

    held = Sidekiq.redis { |redis| redis.get(described_class.lock_key(user.id)) }
    expect(held).to be_nil
  end

  it 'releases the lock even if the tiering run raises' do
    allow(Points::Lod::Tiering).to receive(:new).and_raise(StandardError, 'boom')

    expect { described_class.perform_now(user.id) }.to raise_error(StandardError, 'boom')

    held = Sidekiq.redis { |redis| redis.get(described_class.lock_key(user.id)) }
    expect(held).to be_nil
  end
end
