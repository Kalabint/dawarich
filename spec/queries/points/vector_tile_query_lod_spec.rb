# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Points::VectorTileQuery do
  let(:user) { create(:user) }

  def lonlat_at(east, north)
    row = ActiveRecord::Base.connection.select_one(
      "SELECT ST_X(p) AS lon, ST_Y(p) AS lat FROM (
         SELECT ST_Transform(ST_SetSRID(ST_MakePoint(#{east}, #{north}), 3857), 4326) AS p
       ) s"
    )
    [row['lon'].to_f, row['lat'].to_f]
  end

  def create_point_at(east, north, attrs = {})
    lon, lat = lonlat_at(east, north)
    create(:point, user:, longitude: lon, latitude: lat, lonlat: "POINT(#{lon} #{lat})", **attrs)
  end

  def executed_sql(z:, x:, y:) # rubocop:disable Naming/MethodParameterName
    statements = []
    collector = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }

    ActiveSupport::Notifications.subscribed(collector, 'sql.active_record') do
      described_class.new(scope: user.points, z: z, x: x, y: y).feature_rows
    end

    statements.join("\n")
  end

  describe 'when DawarichSettings.points_lod_enabled? returns true' do
    before { allow(DawarichSettings).to receive(:points_lod_enabled?).and_return(true) }

    it 'carries the d_log2 predicate at a filtered zoom and still returns the matching point' do
      create_point_at(10, 10, d_log2: 9, timestamp: 1_720_000_000)

      sql = executed_sql(z: 9, x: 256, y: 255)
      expect(sql).to include('points.d_log2 >= 8')

      rows = described_class.new(scope: user.points, z: 9, x: 256, y: 255).feature_rows
      expect(rows.sum { |r| r['count'].to_i }).to eq(1)
    end

    it 'reads a finer tier nearer the pole, where a metre spans more pixels' do
      expect(executed_sql(z: 9, x: 256, y: 150)).to include('points.d_log2 >= 7')
    end

    it 'omits the predicate at full detail' do
      sql = executed_sql(z: 19, x: 0, y: 0)

      expect(sql).not_to include('points.d_log2')
    end

    it 'excludes a point whose d_log2 is below the zoom tier' do
      create_point_at(10, 10, d_log2: 3, timestamp: 1_720_000_000)

      rows = described_class.new(scope: user.points, z: 9, x: 256, y: 255).feature_rows
      expect(rows.sum { |r| r['count'].to_i }).to eq(0)
    end
  end

  describe 'when DawarichSettings.points_lod_enabled? returns false' do
    before { allow(DawarichSettings).to receive(:points_lod_enabled?).and_return(false) }

    it 'never adds the d_log2 predicate, regardless of zoom' do
      sql = executed_sql(z: 9, x: 256, y: 255)

      expect(sql).not_to include('points.d_log2')
    end

    it 'still returns a point with no d_log2 at all (pre-feature data)' do
      create_point_at(10, 10, d_log2: nil, timestamp: 1_720_000_000)

      rows = described_class.new(scope: user.points, z: 9, x: 256, y: 255).feature_rows
      expect(rows.sum { |r| r['count'].to_i }).to eq(1)
    end
  end
end
