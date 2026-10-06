# frozen_string_literal: true

module Points
  module Lod
    # KalaMaps' distance-tier chain (pruner_core.py: assign_levels), minus its
    # dithered pick: a tier keeps the point that crosses its distance, so every
    # dropped point lies within one tier distance of a kept one.
    class Chain
      R_METERS = 6_371_008.8 # matches PostGIS ST_DistanceSphere

      TIERS = 12.downto(3).map { |n| { log2_m: n, distance_m: 2**n } }.freeze
      COARSEST_LOG2_M = TIERS.first.fetch(:log2_m)
      FINEST_LOG2_M = TIERS.last.fetch(:log2_m) # 3: every point starts here, no decimation needed
      GAP_SECONDS = 3_600 # Dawarich's own track-split threshold; resets the chain

      COARSENING_TIERS = TIERS[0..-2].reverse.freeze

      def self.haversine_m(lon1, lat1, lon2, lat2)
        p1 = lat1 * Math::PI / 180
        p2 = lat2 * Math::PI / 180
        dphi = (lat2 - lat1) * Math::PI / 180
        dlmb = (lon2 - lon1) * Math::PI / 180
        h = (Math.sin(dphi / 2)**2) + (Math.cos(p1) * Math.cos(p2) * (Math.sin(dlmb / 2)**2))

        R_METERS * 2 * Math.asin(Math.sqrt(h))
      end

      def initialize(on_reset: -> {}, &on_level)
        raise ArgumentError, 'Points::Lod::Chain requires an on_level block' unless on_level

        @on_level = on_level
        @on_reset = on_reset
        @head = build_pipeline
        @last_timestamp = nil
      end

      def push(point)
        if @last_timestamp && (point[:timestamp] - @last_timestamp) > GAP_SECONDS
          @on_reset.call
          @head = build_pipeline
        end
        @last_timestamp = point[:timestamp]

        @on_level.call(point[:id], FINEST_LOG2_M)
        @head.feed(point)
      end
      alias << push

      private

      def build_pipeline
        next_stage = nil

        COARSENING_TIERS.reverse_each do |tier|
          stage_log2 = tier.fetch(:log2_m)
          forward = next_stage
          on_survive = lambda do |point|
            @on_level.call(point[:id], stage_log2)
            forward&.feed(point)
          end
          next_stage = Decimator.new(tier.fetch(:distance_m), &on_survive)
        end

        next_stage
      end

      class Decimator
        def initialize(distance_m, &on_survive)
          @distance_m = distance_m
          @on_survive = on_survive
          @last = nil
        end

        def feed(point)
          return if @last && Chain.haversine_m(point[:lon], point[:lat], @last[:lon], @last[:lat]) <= @distance_m

          @last = point
          @on_survive.call(point)
        end
      end
    end
  end
end
