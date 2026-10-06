# frozen_string_literal: true

class Points::LodSchedulingJob < ApplicationJob
  queue_as :low_priority

  def perform
    return unless DawarichSettings.points_lod_enabled?

    pending_user_ids.each { |user_id| Points::LodJob.perform_later(user_id) }
  end

  private

  def pending_user_ids
    pending = Point.where('anomaly IS NOT TRUE').where('lonlat IS NOT NULL').where(d_log2: nil)
    dirty = Point.where('anomaly IS TRUE').where.not(d_log2: nil)

    (pending.distinct.pluck(:user_id) + dirty.distinct.pluck(:user_id)).uniq
  end
end
