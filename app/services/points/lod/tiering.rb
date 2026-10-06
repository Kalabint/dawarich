# frozen_string_literal: true

module Points
  module Lod
    class Tiering
      READ_BATCH = 50_000
      WRITE_CHUNK = 5_000
      MAX_DEADLOCK_RETRIES = 5
      DEADLOCK_RETRY_BASE_SECONDS = 0.2
      ROW_COLUMNS = [
        :id, :timestamp, :anomaly, Arel.sql('ST_X(lonlat::geometry)'), Arel.sql('ST_Y(lonlat::geometry)')
      ].freeze

      def initialize(user_id, full: false)
        @user_id = user_id
        @full = full
      end

      def call
        partitions.each { |tracker_key| tier_partition(tracker_key) }
      end

      private

      attr_reader :user_id

      def full?
        @full
      end

      def partitions
        scope = Point.where(user_id: user_id)
        unless full?
          scope = scope.where('(d_log2 IS NULL AND anomaly IS NOT TRUE AND lonlat IS NOT NULL) ' \
                              'OR (anomaly IS TRUE AND d_log2 IS NOT NULL)')
        end
        scope.distinct.pluck(Arel.sql("COALESCE(tracker_id, '')"))
      end

      def tier_partition(tracker_key)
        start_point =
          if full?
            nil
          else
            boundary = restart_boundary(tracker_key)
            return if boundary.nil?

            boundary
          end

        recompute_from(tracker_key, start_point)
      end

      def restart_boundary(tracker_key)
        trigger = [earliest(pending_scope(tracker_key)), earliest(dirty_anomaly_scope(tracker_key))]
                  .compact.min_by { |ts, id| [ts, id] }
        return nil unless trigger

        anchor = last_tiered_before(tracker_key, trigger) || trigger
        segment_start_at_or_before(tracker_key, anchor)
      end

      def earliest(scope)
        scope.order(:timestamp, :id).limit(1).pick(:timestamp, :id)
      end

      def pending_scope(tracker_key)
        partition_scope(tracker_key)
          .where('anomaly IS NOT TRUE')
          .where('lonlat IS NOT NULL')
          .where(d_log2: nil)
      end

      def dirty_anomaly_scope(tracker_key)
        partition_scope(tracker_key)
          .where('anomaly IS TRUE')
          .where.not(d_log2: nil)
      end

      def last_tiered_before(tracker_key, trigger)
        ts, id = trigger
        partition_scope(tracker_key)
          .where('anomaly IS NOT TRUE')
          .where('lonlat IS NOT NULL')
          .where.not(d_log2: nil)
          .where('(timestamp, id) < (?, ?)', ts, id)
          .order(timestamp: :desc, id: :desc)
          .limit(1)
          .pick(:timestamp, :id)
      end

      def segment_start_at_or_before(tracker_key, point)
        ts, id = point
        sql = Point.sanitize_sql_array([<<~SQL, user_id, tracker_key, ts, id])
          SELECT timestamp, id FROM (
            SELECT id, timestamp,
              timestamp - LEAD(timestamp) OVER (ORDER BY timestamp DESC, id DESC) AS gap
            FROM points
            WHERE user_id = ? AND COALESCE(tracker_id, '') = ?
              AND anomaly IS NOT TRUE AND lonlat IS NOT NULL
              AND (timestamp, id) <= (?, ?)
            ORDER BY timestamp DESC, id DESC
          ) segmented
          WHERE gap IS NULL OR gap > #{Points::Lod::Chain::GAP_SECONDS}
          LIMIT 1
        SQL
        row = Point.connection.select_one(sql)
        return nil unless row

        [row['timestamp'].to_i, row['id'].to_i]
      end

      def partition_scope(tracker_key)
        Point.where(user_id: user_id).where("COALESCE(tracker_id, '') = ?", tracker_key)
      end

      def recompute_from(tracker_key, start_point)
        scope = partition_scope(tracker_key)
        if start_point
          ts, id = start_point
          scope = scope.where('(timestamp, id) >= (?, ?)', ts, id)
        end

        buffer = {}
        chain = Points::Lod::Chain.new(on_reset: -> { flush!(buffer) }) { |pid, level| buffer[pid] = level }

        each_row(scope) do |id, ts, anomaly, lon, lat|
          if anomaly || lon.nil?
            buffer[id] = nil
            next
          end

          chain.push(id: id, timestamp: ts, lon: lon, lat: lat)
        end

        flush!(buffer)
      end

      def each_row(scope, &block)
        last_ts = nil
        last_id = nil

        loop do
          page = scope
          page = page.where('(timestamp, id) > (?, ?)', last_ts, last_id) if last_ts
          rows = page.order(:timestamp, :id).limit(READ_BATCH).pluck(*ROW_COLUMNS)
          break if rows.empty?

          rows.each(&block)

          last_id = rows.last[0]
          last_ts = rows.last[1]
          break if rows.size < READ_BATCH
        end
      end

      def flush!(buffer)
        return if buffer.empty?

        buffer.sort.each_slice(WRITE_CHUNK) { |slice| write_chunk(slice) }
        buffer.clear
      end

      def write_chunk(pairs)
        values = pairs.map do |id, level|
          "(#{id.to_i}::bigint, #{level.nil? ? 'NULL' : level.to_i}::smallint)"
        end.join(',')
        sql = <<~SQL
          UPDATE points SET d_log2 = v.d
          FROM (VALUES #{values}) AS v(id, d)
          WHERE points.id = v.id AND points.d_log2 IS DISTINCT FROM v.d
        SQL

        attempts = 0
        begin
          Point.transaction { Point.connection.execute(sql) }
        rescue ActiveRecord::Deadlocked
          attempts += 1
          raise if attempts >= MAX_DEADLOCK_RETRIES

          sleep(DEADLOCK_RETRY_BASE_SECONDS * attempts)
          retry
        end
      end
    end
  end
end
