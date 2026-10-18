# frozen_string_literal: true

module Muni
  module Transit
    # Historical on-time performance (OTP), punctuality benchmarks, and corridor groupings.
    module Performance
      CAMBRIDGE_ROUTES = %w[Red CR-Fitchburg Green-D Green-E].freeze
      BOSTON_ROUTES = %w[
        Red Orange Blue Green-B Green-C Green-D Green-E Mattapan
        CR-Worcester CR-Providence CR-Fitchburg CR-Lowell CR-Haverhill CR-Newburyport
        CR-Franklin CR-Needham CR-Middleborough CR-Kingston CR-Greenbush CR-Fairmount
        CR-NewBedford CR-Foxboro
      ].freeze

      SYSTEM_OVERVIEW = {
        overall_otp: 89.6,
        prior_year_overall_otp: 74.2,
        subway_otp: 84.8,
        commuter_rail_otp: 93.4,
        slow_zones_removed_systemwide: 228,
        travel_time_saved_daily_minutes: 2_400_000,
        total_monthly_trips_tracked: 48_650,
        top_performing_line: {
          name: 'Fairmount Line',
          otp: 97.4,
          color: '#80276C',
          route_id: 'CR-Fairmount'
        },
        most_improved_line: {
          name: 'Red Line',
          delta: 19.8,
          color: '#DA291C',
          route_id: 'Red'
        }
      }.freeze

      LINE_PERFORMANCE = [
        {
          route_id: 'Red',
          name: 'Red Line',
          mode: 'subway',
          color: '#DA291C',
          terminals: 'Alewife ↔ Ashmont / Braintree',
          current_otp: 84.6,
          prior_year_otp: 64.8,
          target_benchmark: 85.0,
          avg_delay_minutes: 3.6,
          slow_zones_cleared: 88,
          slow_zone_miles_remaining: 0.2,
          trend: 'up',
          corridors: %w[cambridge boston]
        },
        {
          route_id: 'Orange',
          name: 'Orange Line',
          mode: 'subway',
          color: '#ED8B00',
          terminals: 'Oak Grove ↔ Forest Hills',
          current_otp: 87.2,
          prior_year_otp: 71.5,
          target_benchmark: 85.0,
          avg_delay_minutes: 2.8,
          slow_zones_cleared: 54,
          slow_zone_miles_remaining: 0.0,
          trend: 'up',
          corridors: %w[boston]
        },
        {
          route_id: 'Blue',
          name: 'Blue Line',
          mode: 'subway',
          color: '#003DA5',
          terminals: 'Wonderland ↔ Bowdoin',
          current_otp: 91.8,
          prior_year_otp: 82.0,
          target_benchmark: 85.0,
          avg_delay_minutes: 1.8,
          slow_zones_cleared: 32,
          slow_zone_miles_remaining: 0.0,
          trend: 'up',
          corridors: %w[boston]
        },
        {
          route_id: 'Green-B',
          name: 'Green Line B',
          mode: 'subway',
          color: '#00843D',
          terminals: 'Boston College ↔ Government Center',
          current_otp: 78.4,
          prior_year_otp: 70.1,
          target_benchmark: 85.0,
          avg_delay_minutes: 4.5,
          slow_zones_cleared: 18,
          slow_zone_miles_remaining: 0.6,
          trend: 'stable',
          corridors: %w[boston]
        },
        {
          route_id: 'Green-C',
          name: 'Green Line C',
          mode: 'subway',
          color: '#00843D',
          terminals: 'Cleveland Circle ↔ Government Center',
          current_otp: 82.1,
          prior_year_otp: 73.4,
          target_benchmark: 85.0,
          avg_delay_minutes: 3.8,
          slow_zones_cleared: 14,
          slow_zone_miles_remaining: 0.4,
          trend: 'up',
          corridors: %w[boston]
        },
        {
          route_id: 'Green-D',
          name: 'Green Line D',
          mode: 'subway',
          color: '#00843D',
          terminals: 'Riverside ↔ Union Square',
          current_otp: 86.5,
          prior_year_otp: 76.2,
          target_benchmark: 85.0,
          avg_delay_minutes: 3.1,
          slow_zones_cleared: 22,
          slow_zone_miles_remaining: 0.1,
          trend: 'up',
          corridors: %w[cambridge boston]
        },
        {
          route_id: 'Green-E',
          name: 'Green Line E',
          mode: 'subway',
          color: '#00843D',
          terminals: 'Heath Street ↔ Medford/Tufts',
          current_otp: 83.9,
          prior_year_otp: 74.8,
          target_benchmark: 85.0,
          avg_delay_minutes: 3.5,
          slow_zones_cleared: 19,
          slow_zone_miles_remaining: 0.3,
          trend: 'up',
          corridors: %w[cambridge boston]
        },
        {
          route_id: 'Mattapan',
          name: 'Mattapan High Speed Line',
          mode: 'subway',
          color: '#DA291C',
          terminals: 'Ashmont ↔ Mattapan',
          current_otp: 88.0,
          prior_year_otp: 81.2,
          target_benchmark: 85.0,
          avg_delay_minutes: 2.2,
          slow_zones_cleared: 8,
          slow_zone_miles_remaining: 0.0,
          trend: 'stable',
          corridors: %w[boston]
        },
        {
          route_id: 'CR-Fitchburg',
          name: 'Fitchburg Line',
          mode: 'commuter_rail',
          color: '#80276C',
          terminals: 'North Station ↔ Fitchburg / Wachusett',
          current_otp: 91.2,
          prior_year_otp: 84.5,
          target_benchmark: 90.0,
          avg_delay_minutes: 2.4,
          slow_zones_cleared: 12,
          slow_zone_miles_remaining: 0.0,
          trend: 'up',
          corridors: %w[cambridge boston]
        },
        {
          route_id: 'CR-Worcester',
          name: 'Framingham/Worcester Line',
          mode: 'commuter_rail',
          color: '#80276C',
          terminals: 'South Station ↔ Worcester',
          current_otp: 90.4,
          prior_year_otp: 83.1,
          target_benchmark: 90.0,
          avg_delay_minutes: 2.7,
          slow_zones_cleared: 16,
          slow_zone_miles_remaining: 0.1,
          trend: 'up',
          corridors: %w[boston]
        },
        {
          route_id: 'CR-Providence',
          name: 'Providence/Stoughton Line',
          mode: 'commuter_rail',
          color: '#80276C',
          terminals: 'South Station ↔ Providence / Wickford',
          current_otp: 92.6,
          prior_year_otp: 86.8,
          target_benchmark: 90.0,
          avg_delay_minutes: 2.1,
          slow_zones_cleared: 10,
          slow_zone_miles_remaining: 0.0,
          trend: 'up',
          corridors: %w[boston]
        },
        {
          route_id: 'CR-Lowell',
          name: 'Lowell Line',
          mode: 'commuter_rail',
          color: '#80276C',
          terminals: 'North Station ↔ Lowell',
          current_otp: 93.8,
          prior_year_otp: 88.2,
          target_benchmark: 90.0,
          avg_delay_minutes: 1.9,
          slow_zones_cleared: 8,
          slow_zone_miles_remaining: 0.0,
          trend: 'up',
          corridors: %w[boston]
        },
        {
          route_id: 'CR-Haverhill',
          name: 'Haverhill Line',
          mode: 'commuter_rail',
          color: '#80276C',
          terminals: 'North Station ↔ Haverhill',
          current_otp: 92.1,
          prior_year_otp: 85.9,
          target_benchmark: 90.0,
          avg_delay_minutes: 2.3,
          slow_zones_cleared: 11,
          slow_zone_miles_remaining: 0.0,
          trend: 'up',
          corridors: %w[boston]
        },
        {
          route_id: 'CR-Newburyport',
          name: 'Newburyport/Rockport Line',
          mode: 'commuter_rail',
          color: '#80276C',
          terminals: 'North Station ↔ Newburyport / Rockport',
          current_otp: 93.5,
          prior_year_otp: 87.0,
          target_benchmark: 90.0,
          avg_delay_minutes: 2.0,
          slow_zones_cleared: 14,
          slow_zone_miles_remaining: 0.0,
          trend: 'up',
          corridors: %w[boston]
        },
        {
          route_id: 'CR-Franklin',
          name: 'Franklin Line',
          mode: 'commuter_rail',
          color: '#80276C',
          terminals: 'South Station ↔ Forge Park / Foxboro',
          current_otp: 92.9,
          prior_year_otp: 86.4,
          target_benchmark: 90.0,
          avg_delay_minutes: 2.2,
          slow_zones_cleared: 9,
          slow_zone_miles_remaining: 0.0,
          trend: 'up',
          corridors: %w[boston]
        },
        {
          route_id: 'CR-Needham',
          name: 'Needham Line',
          mode: 'commuter_rail',
          color: '#80276C',
          terminals: 'South Station ↔ Needham Heights',
          current_otp: 94.1,
          prior_year_otp: 89.0,
          target_benchmark: 90.0,
          avg_delay_minutes: 1.7,
          slow_zones_cleared: 6,
          slow_zone_miles_remaining: 0.0,
          trend: 'up',
          corridors: %w[boston]
        },
        {
          route_id: 'CR-Middleborough',
          name: 'Middleborough/Lakeville Line',
          mode: 'commuter_rail',
          color: '#80276C',
          terminals: 'South Station ↔ Middleborough',
          current_otp: 93.0,
          prior_year_otp: 87.5,
          target_benchmark: 90.0,
          avg_delay_minutes: 2.0,
          slow_zones_cleared: 7,
          slow_zone_miles_remaining: 0.0,
          trend: 'up',
          corridors: %w[boston]
        },
        {
          route_id: 'CR-Kingston',
          name: 'Kingston Line',
          mode: 'commuter_rail',
          color: '#80276C',
          terminals: 'South Station ↔ Kingston',
          current_otp: 94.3,
          prior_year_otp: 88.9,
          target_benchmark: 90.0,
          avg_delay_minutes: 1.8,
          slow_zones_cleared: 5,
          slow_zone_miles_remaining: 0.0,
          trend: 'up',
          corridors: %w[boston]
        },
        {
          route_id: 'CR-Greenbush',
          name: 'Greenbush Line',
          mode: 'commuter_rail',
          color: '#80276C',
          terminals: 'South Station ↔ Greenbush',
          current_otp: 95.2,
          prior_year_otp: 89.7,
          target_benchmark: 90.0,
          avg_delay_minutes: 1.5,
          slow_zones_cleared: 4,
          slow_zone_miles_remaining: 0.0,
          trend: 'up',
          corridors: %w[boston]
        },
        {
          route_id: 'CR-Fairmount',
          name: 'Fairmount Line',
          mode: 'commuter_rail',
          color: '#80276C',
          terminals: 'South Station ↔ Readville',
          current_otp: 97.4,
          prior_year_otp: 91.2,
          target_benchmark: 90.0,
          avg_delay_minutes: 1.1,
          slow_zones_cleared: 3,
          slow_zone_miles_remaining: 0.0,
          trend: 'up',
          corridors: %w[boston]
        },
        {
          route_id: 'CR-NewBedford',
          name: 'Fall River/New Bedford Line',
          mode: 'commuter_rail',
          color: '#80276C',
          terminals: 'South Station ↔ New Bedford',
          current_otp: 95.8,
          prior_year_otp: 90.0,
          target_benchmark: 90.0,
          avg_delay_minutes: 1.4,
          slow_zones_cleared: 2,
          slow_zone_miles_remaining: 0.0,
          trend: 'up',
          corridors: %w[boston]
        },
        {
          route_id: 'CR-Foxboro',
          name: 'Foxboro Line',
          mode: 'commuter_rail',
          color: '#80276C',
          terminals: 'South Station ↔ Foxboro',
          current_otp: 96.1,
          prior_year_otp: 90.5,
          target_benchmark: 90.0,
          avg_delay_minutes: 1.3,
          slow_zones_cleared: 2,
          slow_zone_miles_remaining: 0.0,
          trend: 'up',
          corridors: %w[boston]
        }
      ].freeze

      class << self
        def system_overview
          SYSTEM_OVERVIEW
        end

        def lines(corridor: nil)
          return LINE_PERFORMANCE if corridor.nil? || corridor.to_s == 'all'

          c = corridor.to_s.downcase
          LINE_PERFORMANCE.select { |l| l[:corridors].include?(c) }
        end

        def summary_for(hall_slug)
          slug = hall_slug.to_s.downcase
          corridor_lines = lines(corridor: slug)
          return system_overview if corridor_lines.empty? || slug == 'all'

          avg_otp = (corridor_lines.sum { |l| l[:current_otp] } / corridor_lines.length).round(1)
          prior_otp = (corridor_lines.sum { |l| l[:prior_year_otp] } / corridor_lines.length).round(1)
          cleared = corridor_lines.sum { |l| l[:slow_zones_cleared] }
          delay = (corridor_lines.sum { |l| l[:avg_delay_minutes] } / corridor_lines.length).round(1)

          {
            hall: slug,
            corridor_count: corridor_lines.length,
            average_otp: avg_otp,
            prior_year_otp: prior_otp,
            delta: (avg_otp - prior_otp).round(1),
            slow_zones_cleared: cleared,
            avg_delay_minutes: delay,
            lines: corridor_lines
          }
        end
      end
    end
  end
end
