require 'muni/beat'
require 'muni/beats/hall_computation'

module Muni
  module Beats
    class CambridgePoliceLog < Muni::Beat
      beat 'cambridge/police_log',
           source: -> { Cambridge::PoliceLog }, every: '1h', mode: :incremental, limit: 500
    end

    class CambridgeCrimeReports < Muni::Beat
      beat 'cambridge/crime_reports',
           source: -> { Cambridge::CrimeReports }, every: '1h', mode: :incremental, limit: 1_000
    end

    class CambridgeDispatchCalls < Muni::Beat
      beat 'cambridge/dispatch_calls',
           source: -> { Cambridge::DispatchCalls }, every: '1h', mode: :incremental, limit: 1_000
    end

    class CambridgeServiceRequests < Muni::Beat
      beat 'cambridge/service_requests',
           source: -> { Cambridge::ServiceRequests }, every: '5m', mode: :incremental, limit: 1_000
    end

    class CambridgeBuildingPermits < Muni::Beat
      beat 'cambridge/building_permits',
           source: -> { Cambridge::BuildingPermits }, every: '6h', mode: :incremental, limit: 500
    end

    class CambridgeNewConstructionPermits < Muni::Beat
      beat 'cambridge/new_construction_permits',
           source: -> { Cambridge::NewConstructionPermits }, every: '6h', mode: :full, limit: 1_000
    end

    class CambridgeDevelopmentLog < Muni::Beat
      beat 'cambridge/development_log',
           source: -> { Cambridge::DevelopmentLog }, every: '1d', mode: :full, limit: 500
    end

    class CambridgeZoningAppeals < Muni::Beat
      beat 'cambridge/zoning_appeals',
           source: -> { Cambridge::ZoningAppeals }, every: '12h', mode: :full, limit: 1_000
    end

    class CambridgeVisionZero < Muni::Beat
      beat 'cambridge/vision_zero_crashes',
           source: -> { Cambridge::VisionZeroCrashes }, every: '6h', mode: :incremental, limit: 1_000
    end

    class CambridgeCpdCrashLog < Muni::Beat
      beat 'cambridge/cpd_crash_log',
           source: -> { Cambridge::CpdCrashLog }, every: '6h', mode: :incremental, limit: 1_000
    end

    class CambridgeTrafficVolumeDaily < Muni::Beat
      beat 'cambridge/traffic_volume_daily',
           source: -> { Cambridge::TrafficVolumeDaily }, every: '1d', mode: :incremental, limit: 1_000
    end

    class CambridgeBicycleCounts < Muni::Beat
      beat 'cambridge/bicycle_counts',
           source: -> { Cambridge::BicycleCounts }, every: '1d', mode: :incremental, limit: 1_000
    end

    class CambridgePedestrianCounts < Muni::Beat
      beat 'cambridge/pedestrian_counts',
           source: -> { Cambridge::PedestrianCounts }, every: '1d', mode: :incremental, limit: 1_000
    end

    class CambridgeTrees < Muni::Beat
      beat 'cambridge/tree_inventory',
           source: -> { Cambridge::TreeInventory }, every: '12h', mode: :full, limit: 10_000, cursor: :offset
    end

    class CambridgeParks < Muni::Beat
      beat 'cambridge/parks',
           source: -> { Cambridge::Parks }, every: '1d', mode: :full, limit: 2_000, prune_stale: true
    end

    class CambridgeFoodTrucks < Muni::Beat
      beat 'cambridge/food_trucks',
           source: -> { Cambridge::FoodTrucks }, every: '12h', mode: :full, limit: 500
    end

    class CambridgeMeteredParkingSpaces < Muni::Beat
      beat 'cambridge/metered_parking_spaces',
           source: -> { Cambridge::MeteredParkingSpaces }, every: '12h', mode: :full, limit: 5_000, prune_stale: true
    end

    class CambridgeCityNews < Muni::Beat
      beat 'cambridge/city_news',
           source: -> { Cambridge::CityNews }, every: '6h', mode: :incremental, limit: 50
    end

    class CambridgeCityCalendar < Muni::Beat
      beat 'cambridge/city_calendar',
           source: -> { Cambridge::CityCalendar }, every: '6h', mode: :full, limit: 500
    end

    class CambridgeTourismEvents < Muni::Beat
      beat 'cambridge/tourism_events',
           source: -> { Cambridge::TourismEvents }, every: '6h', mode: :full, limit: 200
    end

    class CambridgePrimegovMeetings < Muni::Beat
      beat 'cambridge/primegov_meetings',
           source: -> { Cambridge::PrimegovMeetings }, every: '1h', mode: :full, limit: 250
    end

    class CambridgePrimegovMeetingRecords < Muni::Beat
      beat 'cambridge/primegov_meeting_records',
           source: -> { Muni::Analytics::NullSource }, every: '1h', mode: :full

      def run!
        started = Time.now.utc
        result = { rows_in: 0, rows_upserted: 0, error: nil }

        begin
          limit = ENV.fetch('MUNI_PRIMEGOV_MEETING_RECORD_LIMIT', '250').to_i
          tally = Muni::Meetings::PrimegovMaterializer.materialize!(hall: 'cambridge', limit: limit, now: started)
          result[:rows_in] = tally[:candidates]
          result[:rows_upserted] = tally[:upserted]
          Muni::Store.bump_seen(self.class.slug, started)
        rescue StandardError => e
          result[:error] = e
          Muni::Logger.instance.error("Beat #{self.class.slug} failed: #{e.class}: #{e.message}")
        ensure
          Muni::Store.log_beat_run(
            slug:          self.class.slug,
            started_at:    started,
            ended_at:      Time.now.utc,
            rows_in:       result[:rows_in],
            rows_upserted: result[:rows_upserted],
            error:         result[:error]
          )
        end

        result
      end
    end

    # Historical Granicus meeting archive (City Council, BZA, Charter Review):
    # metadata + agenda/minutes/video links. Summaries are filled separately by
    # CambridgeMeetingsSummary so a Claude outage never blocks ingestion.
    class CambridgeMeetings < Muni::Beat
      beat 'cambridge/meetings',
           source: -> { Cambridge::Meetings }, every: '6h', mode: :incremental, limit: 60
    end

    class CambridgeCambridgeLife < Muni::Beat
      beat 'cambridge/cambridge_life',
           source: -> { Cambridge::CambridgeLife }, every: '1d', mode: :incremental, limit: 50
    end

    class CambridgeCambridgeDay < Muni::Beat
      beat 'cambridge/cambridge_day',
           source: -> { Cambridge::CambridgeDay }, every: '6h', mode: :incremental, limit: 40
    end

    class CambridgeConstructionHighlights < Muni::Beat
      beat 'cambridge/construction_highlights',
           source: -> { Cambridge::ConstructionHighlights }, every: '6h', mode: :incremental, limit: 80
    end

    class CambridgeCityConstructionProjects < Muni::Beat
      beat 'cambridge/city_construction_projects',
           source: -> { Cambridge::CityConstructionProjects }, every: '1d', mode: :incremental, limit: 80
    end

    class CambridgePracticalServices < Muni::Beat
      beat 'cambridge/practical_services',
           source: -> { Cambridge::PracticalServices }, every: '1d', mode: :incremental, limit: 60
    end

    class CambridgeAnalytics < HallAnalytics
      beat 'cambridge/analytics',
           source: -> { Muni::Analytics::NullSource }, every: '6h', mode: :full
    end

    class CambridgeDigest < HallDigest
      beat 'cambridge/digest',
           source: -> { Muni::Analytics::NullSource }, every: '6h', mode: :full
    end

    # Fills ai_summary/key_topics for meetings that don't have one yet, a bounded
    # batch per run. No-ops when ANTHROPIC_API_KEY is unset; each meeting is
    # summarized independently so one bad PDF can't fail the batch.
    class CambridgeMeetingsSummary < Muni::Beat
      beat 'cambridge/meetings_summary',
           source: -> { Muni::Analytics::NullSource }, every: '6h', mode: :full

      def run!
        started = Time.now.utc
        result = { rows_in: 0, rows_upserted: 0, error: nil }

        begin
          client = Muni::AnthropicClient.new
          if client.configured?
            limit = ENV.fetch('MUNI_MEETINGS_SUMMARY_LIMIT', '5').to_i
            tally = Muni::Meetings::Summarizer.summarize_pending(hall: 'cambridge', limit: limit, client: client)
            result[:rows_in] = tally[:candidates]
            result[:rows_upserted] = tally[:summarized]
          end
          Muni::Store.bump_seen(self.class.slug, started)
        rescue StandardError => e
          result[:error] = e
          Muni::Logger.instance.error("Beat #{self.class.slug} failed: #{e.class}: #{e.message}")
        ensure
          Muni::Store.log_beat_run(
            slug:          self.class.slug,
            started_at:    started,
            ended_at:      Time.now.utc,
            rows_in:       result[:rows_in],
            rows_upserted: result[:rows_upserted],
            error:         result[:error]
          )
        end

        result
      end
    end
  end
end
