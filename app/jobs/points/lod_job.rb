# frozen_string_literal: true

class Points::LodJob < ApplicationJob
  queue_as :points_lod

  LOCK_TTL = 1.hour

  def self.lock_key(user_id)
    "points_lod:user:#{user_id}"
  end

  def perform(user_id, full: false)
    return unless DawarichSettings.points_lod_enabled?

    lock_key = self.class.lock_key(user_id)
    acquired = Sidekiq.redis { |redis| redis.set(lock_key, 1, nx: true, ex: LOCK_TTL.to_i) }
    return unless acquired

    begin
      Points::Lod::Tiering.new(user_id, full: full).call
    ensure
      Sidekiq.redis { |redis| redis.del(lock_key) }
    end
  end
end
