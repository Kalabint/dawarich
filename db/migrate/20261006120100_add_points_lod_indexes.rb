# frozen_string_literal: true

class AddPointsLodIndexes < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  MIN_INDEXED_LOG2_M = 7
  MAX_LOG2_M = 12
  PENDING_INDEX = 'index_points_on_user_id_pending_lod'
  DIRTY_ANOMALY_INDEX = 'index_points_on_user_id_dirty_lod_anomaly'

  def up
    execute 'SET lock_timeout = 0'

    enable_extension 'btree_gist'

    (MIN_INDEXED_LOG2_M..MAX_LOG2_M).each do |n|
      add_index :points, %i[lonlat user_id timestamp],
                name: "points_lod_d#{n}",
                using: :gist,
                where: "d_log2 >= #{n}",
                algorithm: :concurrently,
                if_not_exists: true
    end

    add_index :points, :user_id,
              name: PENDING_INDEX,
              where: 'd_log2 IS NULL AND anomaly IS NOT TRUE AND lonlat IS NOT NULL',
              algorithm: :concurrently,
              if_not_exists: true

    add_index :points, :user_id,
              name: DIRTY_ANOMALY_INDEX,
              where: 'anomaly IS TRUE AND d_log2 IS NOT NULL',
              algorithm: :concurrently,
              if_not_exists: true
  end

  def down
    execute 'SET lock_timeout = 0'

    (MIN_INDEXED_LOG2_M..MAX_LOG2_M).each do |n|
      remove_index :points, name: "points_lod_d#{n}", algorithm: :concurrently, if_exists: true
    end

    remove_index :points, name: PENDING_INDEX, algorithm: :concurrently, if_exists: true
    remove_index :points, name: DIRTY_ANOMALY_INDEX, algorithm: :concurrently, if_exists: true
  end
end
