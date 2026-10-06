# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Points::Lod::Chain do
  def point_at(id, meters_north, timestamp)
    lat = 47.0 + ((meters_north / described_class::R_METERS) * (180.0 / Math::PI))
    { id: id, lon: 8.0, lat: lat, timestamp: timestamp }
  end

  def walking_track(step_pattern, start_id: 1, start_ts: 1_700_000_000)
    cumulative = 0
    step_pattern.each_with_index.map do |step, i|
      cumulative += step
      point_at(start_id + i, cumulative, start_ts + (i * 10))
    end
  end

  def levels_for(points)
    levels = {}
    chain = described_class.new { |id, level| levels[id] = level }
    points.each { |p| chain.push(p) }
    levels
  end

  let(:steps) do
    pattern = [2, 3, 5, 12, 2, 40, 90, 3, 2, 300, 700, 1_500, 4, 3_000, 9, 9_000, 2, 20_000, 5, 2]
    pattern * 3
  end

  describe 'nested subset property' do
    it 'keeps every coarser tier a subset of the next finer one' do
      levels = levels_for(walking_track(steps))

      described_class::TIERS.map { |t| t[:log2_m] }.sort.each_cons(2) do |finer, coarser|
        finer_ids = levels.select { |_, l| l >= finer }.keys
        coarser_ids = levels.select { |_, l| l >= coarser }.keys

        expect(coarser_ids - finer_ids).to be_empty
      end
    end
  end

  describe 'first point of a segment' do
    it 'gets the coarsest tier' do
      levels = levels_for(walking_track(steps))

      expect(levels[1]).to eq(described_class::TIERS.first[:log2_m])
    end
  end

  describe 'every tiered point' do
    it 'gets at least the finest tier (3)' do
      levels = levels_for(walking_track(steps))

      expect(levels.values).to all(be >= described_class::FINEST_LOG2_M)
      expect(levels.size).to eq(steps.size)
    end
  end

  describe 'every dropped point' do
    it 'lies within the tier distance of the last point kept at that tier' do
      track = walking_track(steps)
      levels = levels_for(track)

      described_class::TIERS.each do |tier|
        last_kept = nil
        track.each do |p|
          next last_kept = p if levels[p[:id]] >= tier[:log2_m]

          gap = described_class.haversine_m(p[:lon], p[:lat], last_kept[:lon], last_kept[:lat])
          expect(gap).to be <= tier[:distance_m]
        end
      end
    end
  end

  describe 'a far fix inside a segment' do
    it 'is kept at every tier it is farther than' do
      levels = {}
      chain = described_class.new { |id, level| levels[id] = level }

      chain.push(point_at(1, 0, 1_700_000_000))
      chain.push(point_at(2, 1, 1_700_000_010))
      chain.push(point_at(3, 12_000, 1_700_000_020))

      expect(levels[3]).to eq(described_class::COARSEST_LOG2_M)
    end
  end

  describe 'determinism' do
    it 'produces identical levels for identical input across separate runs' do
      track = walking_track(steps)

      expect(levels_for(track)).to eq(levels_for(track))
    end
  end

  describe 'reset at a time gap > GAP_SECONDS' do
    it 'treats the point after the gap as the start of a new segment' do
      levels = {}
      chain = described_class.new { |id, level| levels[id] = level }

      chain.push(point_at(1, 0, 1_700_000_000))
      chain.push(point_at(2, 1, 1_700_000_010)) # tiny hop, dropped by every coarser tier
      chain.push(point_at(3, 2, 1_700_000_010 + described_class::GAP_SECONDS + 1))

      expect(levels[3]).to eq(described_class::TIERS.first[:log2_m])
    end

    it 'calls on_reset exactly when the gap is crossed' do
      resets = 0
      chain = described_class.new(on_reset: -> { resets += 1 }) { |_id, _level| nil }

      chain.push(point_at(1, 0, 1_700_000_000))
      chain.push(point_at(2, 1, 1_700_000_010))
      expect(resets).to eq(0)

      chain.push(point_at(3, 2, 1_700_000_010 + described_class::GAP_SECONDS + 1))
      expect(resets).to eq(1)
    end

    it 'does not reset for a gap at or under the threshold' do
      resets = 0
      chain = described_class.new(on_reset: -> { resets += 1 }) { |_id, _level| nil }

      chain.push(point_at(1, 0, 1_700_000_000))
      chain.push(point_at(2, 1, 1_700_000_000 + described_class::GAP_SECONDS))

      expect(resets).to eq(0)
    end
  end
end
