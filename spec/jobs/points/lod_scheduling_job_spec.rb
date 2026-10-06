# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Points::LodSchedulingJob, type: :job do
  before { allow(DawarichSettings).to receive(:points_lod_enabled?).and_return(true) }

  it 'enqueues Points::LodJob for a user with a never-tiered point' do
    user = create(:user)
    create(:point, user: user, d_log2: nil, anomaly: false)

    expect { described_class.perform_now }
      .to have_enqueued_job(Points::LodJob).with(user.id).on_queue('points_lod').exactly(:once)
  end

  it 'enqueues Points::LodJob for a user with a dirty anomaly (tiered, then flagged anomaly)' do
    user = create(:user)
    create(:point, user: user, d_log2: 7, anomaly: true)

    expect { described_class.perform_now }.to have_enqueued_job(Points::LodJob).with(user.id).exactly(:once)
  end

  it 'enqueues a user only once even with both a pending point and a dirty anomaly' do
    user = create(:user)
    create(:point, user: user, d_log2: nil, anomaly: false)
    create(:point, user: user, d_log2: 7, anomaly: true)

    expect { described_class.perform_now }.to have_enqueued_job(Points::LodJob).with(user.id).exactly(:once)
  end

  it 'does not enqueue a user whose points are already fully tiered' do
    user = create(:user)
    create(:point, user: user, d_log2: 9, anomaly: false)

    expect { described_class.perform_now }.not_to have_enqueued_job(Points::LodJob)
  end

  it 'does not enqueue anyone when the feature flag is off' do
    allow(DawarichSettings).to receive(:points_lod_enabled?).and_return(false)
    create(:point, d_log2: nil, anomaly: false)

    expect { described_class.perform_now }.not_to have_enqueued_job(Points::LodJob)
  end
end
