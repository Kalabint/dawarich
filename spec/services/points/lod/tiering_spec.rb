# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Points::Lod::Tiering do
  def lat_for(meters_north)
    47.0 + ((meters_north / Points::Lod::Chain::R_METERS) * (180.0 / Math::PI))
  end

  def create_point(user, meters_north, timestamp, anomaly: false)
    lon = 8.0
    lat = lat_for(meters_north)
    create(:point, user: user, timestamp: timestamp, longitude: lon, latitude: lat,
                   lonlat: "POINT(#{lon} #{lat})", anomaly: anomaly)
  end

  def tiered_state(user)
    user.points.order(:timestamp, :id).pluck(:timestamp, :d_log2)
  end

  def executed_update_count(&block)
    count = 0
    collector = lambda { |_name, _start, _finish, _id, payload|
      count += 1 if payload[:sql].to_s.include?('UPDATE points SET d_log2')
    }

    ActiveSupport::Notifications.subscribed(collector, 'sql.active_record', &block)
    count
  end

  let(:user) { create(:user) }

  let(:start_ts) { 1_700_000_000 }
  let(:seg1_steps) { [2, 3, 5, 12, 2, 40, 90, 3, 2, 300] }
  let(:seg2_gap) { 4_000 } # > Chain::GAP_SECONDS
  let(:seg2_steps) { [700, 1_500, 4, 3_000, 9, 9_000, 2, 20_000, 5, 2] }

  def build_initial_track
    cumulative = 0
    seg1_steps.each_with_index do |step, i|
      cumulative += step
      create_point(user, cumulative, start_ts + (i * 10))
    end
    seg1_end_ts = start_ts + ((seg1_steps.size - 1) * 10)

    seg2_start_ts = seg1_end_ts + seg2_gap
    seg2_steps.each_with_index do |step, i|
      cumulative += step
      create_point(user, cumulative, seg2_start_ts + (i * 10))
    end

    { cumulative: cumulative, seg1_end_ts: seg1_end_ts, seg2_start_ts: seg2_start_ts }
  end

  it 'computes an initial incremental run identical to a fresh full run on the same data, keeps anomalies NULL, ' \
     'bridges a gap and a mid-segment insert correctly, and writes nothing on a no-op re-run' do
    state = build_initial_track

    described_class.new(user.id).call

    mid_ts = start_ts + 35
    create_point(user, state[:cumulative] + 1, mid_ts)

    bridge_ts = state[:seg1_end_ts] + 1_800
    create_point(user, state[:cumulative] + 50, bridge_ts)
    expect(state[:seg2_start_ts] - bridge_ts).to be <= Points::Lod::Chain::GAP_SECONDS

    tail_start_ts = state[:seg2_start_ts] + ((seg2_steps.size - 1) * 10) + 100
    cumulative = state[:cumulative]
    [3, 7, 2, 50, 4].each_with_index do |step, i|
      cumulative += step
      create_point(user, cumulative, tail_start_ts + (i * 10), anomaly: i == 2)
    end

    dirty = user.points.find_by!(timestamp: start_ts + 40) # seg1 step index 4
    dirty.update_columns(anomaly: true)

    described_class.new(user.id).call

    incremental_final = tiered_state(user)

    expect(user.points.find_by!(timestamp: start_ts + 40).d_log2).to be_nil
    anomaly_tail_ts = tail_start_ts + (2 * 10)
    expect(user.points.find_by!(timestamp: anomaly_tail_ts).d_log2).to be_nil

    non_anomaly_levels = user.points.where('anomaly IS NOT TRUE').pluck(:d_log2)
    expect(non_anomaly_levels).to all(be_present)

    user.points.update_all(d_log2: nil)
    described_class.new(user.id, full: true).call

    expect(incremental_final).to eq(tiered_state(user))

    update_count = executed_update_count { described_class.new(user.id).call }
    expect(update_count).to eq(0)
  end

  it 'retries a chunk write that hits a deadlock and still tiers the point' do
    create_point(user, 10, start_ts)
    attempts = 0

    allow(Point.connection).to receive(:execute).and_wrap_original do |original, sql|
      if sql.include?('UPDATE points SET d_log2') && (attempts += 1) <= 2
        raise ActiveRecord::Deadlocked, 'simulated deadlock'
      end

      original.call(sql)
    end
    tiering = described_class.new(user.id)
    allow(tiering).to receive(:sleep) # keep the retry loop fast
    tiering.call

    expect(attempts).to eq(3)
    expect(user.points.first.d_log2).to eq(Points::Lod::Chain::TIERS.first[:log2_m])
  end
end
