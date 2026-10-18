module Muni
  module Dashboard
    module SourceStatus
      SOURCE_NOTES = [
        [
          'cambridge/service_requests',
          'Closure time is inferred from opened and closed timestamps in the city feed.'
        ],
        [
          'cambridge/police_log',
          'Published police log pipeline, not a citywide crime-rate or live dispatch feed; ' \
          'locations may be delayed or approximate.'
        ],
        [
          'cambridge/crime_reports',
          'Official crime reports by reporting area; locations are approximate.'
        ],
        [
          'cambridge/dispatch_calls',
          'Fire and police CAD calls with masked block-level locations; EMS is not included.'
        ],
        [
          'cambridge/building_permits',
          'Permit activity reflects official issue dates from the addition/alteration feed.'
        ],
        [
          'cambridge/vision_zero_crashes',
          'Official crash feed is delayed/quarterly and should not be read as live incidents.'
        ],
        [
          'cambridge/cpd_crash_log',
          'Fresh CPD crash log used as a supplement while continuity is evaluated.'
        ],
        [
          'cambridge/traffic_volume_daily',
          'Miovision traffic counts stored as daily rollups, not raw movement rows.'
        ],
        [
          'cambridge/bicycle_counts',
          'Citywide bicycle counts are periodic observations, not live traffic.'
        ],
        [
          'cambridge/pedestrian_counts',
          'Daily pedestrian counts are aggregate exposure data.'
        ],
        [
          'cambridge/tree_inventory',
          'Inventory data is refreshed in batches rather than as a real-time event stream.'
        ],
        [
          'cambridge/city_news',
          'Official Cambridge news and service notices used for Digest source facts.'
        ],
        [
          'cambridge/city_calendar',
          'Official city calendar listings for today and upcoming civic events.'
        ],
        [
          'cambridge/tourism_events',
          'Official Cambridge Office for Tourism event listings filtered to Cambridge venues.'
        ],
        [
          'cambridge/primegov_meetings',
          'Official PrimeGov public meeting portal details, agendas, and comment status when published.'
        ],
        [
          'cambridge/cambridge_life',
          'Official magazine-style Cambridge Life and CityView publication metadata.'
        ],
        [
          'cambridge/cambridge_day',
          'Local press headline and excerpt metadata only; article bodies are not ingested.'
        ],
        [
          'cambridge/construction_highlights',
          'Weekly official construction highlights and street-level impacts.'
        ],
        [
          'cambridge/city_construction_projects',
          'Official construction project and construction-map metadata.'
        ],
        [
          'cambridge/practical_services',
          'Official city service reminder pages for street cleaning, curbside collections, ' \
          'and alert subscriptions.'
        ]
      ].to_h.freeze

      SOURCE_MODES = [
        ['cambridge/service_requests', 'live'],
        ['cambridge/police_log', 'delayed'],
        ['cambridge/crime_reports', 'delayed'],
        ['cambridge/dispatch_calls', 'delayed'],
        ['cambridge/building_permits', 'delayed'],
        ['cambridge/new_construction_permits', 'delayed'],
        ['cambridge/development_log', 'inventory'],
        ['cambridge/zoning_appeals', 'delayed'],
        ['cambridge/vision_zero_crashes', 'delayed'],
        ['cambridge/cpd_crash_log', 'delayed'],
        ['cambridge/traffic_volume_daily', 'representative_sensor'],
        ['cambridge/bicycle_counts', 'representative_sensor'],
        ['cambridge/pedestrian_counts', 'representative_sensor'],
        ['cambridge/tree_inventory', 'inventory'],
        ['cambridge/parks', 'inventory'],
        ['cambridge/food_trucks', 'inventory'],
        ['cambridge/metered_parking_spaces', 'inventory'],
        ['cambridge/meetings', 'delayed'],
        ['cambridge/city_news', 'digest'],
        ['cambridge/city_calendar', 'digest'],
        ['cambridge/tourism_events', 'digest'],
        ['cambridge/primegov_meetings', 'digest'],
        ['cambridge/cambridge_life', 'digest'],
        ['cambridge/cambridge_day', 'digest'],
        ['cambridge/construction_highlights', 'digest'],
        ['cambridge/city_construction_projects', 'digest'],
        ['cambridge/practical_services', 'digest']
      ].to_h.freeze

      SOURCE_COMPLETENESS = [
        %w[live citywide_operational_feed],
        %w[delayed official_delayed_feed],
        %w[inventory official_inventory_snapshot],
        %w[representative_sensor representative_sensor_network],
        %w[digest source_curated_digest],
        %w[experimental under_evaluation]
      ].to_h.freeze

      def source_statuses(hall)
        Muni::View.for_hall(hall).filter_map do |category|
          source_slug = Muni::View.primary_source(category.slug, hall)
          next unless source_slug

          source_status_row(category, source_slug)
        end
      end

      def source_status_row(category, source_slug)
        beat = Muni::Registry.beat(source_slug)
        latest_run = Muni::Store.latest_beat_run(source_slug)
        latest_success = Muni::Store.latest_beat_run(source_slug, successful: true)
        data_freshness = source_data_freshness(source_slug)
        mode = source_mode(source_slug)
        {
          category:           category.slug.to_s,
          label:              category.title,
          source:             source_slug,
          source_mode:        mode,
          completeness:       source_completeness(mode),
          cadence:            beat&.every,
          last_run_at:        iso_time(latest_run&.[](:ended_at)),
          last_success_at:    iso_time(latest_success&.[](:ended_at)),
          last_seen_at:       iso_time(Muni::Store.last_seen(source_slug)),
          last_checked_at:    iso_time(Muni::Store.last_checked(source_slug)),
          latest_data_at:     iso_time(data_freshness[:latest_data_at]),
          last_collected_at:  iso_time(data_freshness[:last_collected_at]),
          latest_opened_at:   iso_time(data_freshness[:latest_opened_at]),
          latest_updated_at:  iso_time(data_freshness[:latest_updated_at]),
          data_lag_seconds:   data_freshness[:data_lag_seconds],
          source_lag_seconds: data_freshness[:source_lag_seconds],
          last_error:         Muni::Status.public_error(latest_run && latest_run[:error]),
          note:               SOURCE_NOTES[source_slug] || catalog_note(source_slug),
          source_url:         catalog_url(source_slug)
        }
      end

      def source_data_freshness(source_slug)
        source = Muni::Registry.source(source_slug)
        return {} unless source

        latest_opened = latest_time(source, :opened_at)
        latest_updated = latest_time(source, :updated_at)
        last_collected = latest_time(source, :collected_at) || latest_time(source, :fetched_at)
        latest_data = [latest_opened, latest_updated, latest_time(source, nil)].compact.max
        data_lag_seconds = latest_data ? [(Time.now.utc - latest_data).to_i, 0].max : nil
        {
          latest_data_at:     latest_data,
          last_collected_at:  last_collected,
          latest_opened_at:   latest_opened,
          latest_updated_at:  latest_updated,
          data_lag_seconds:   data_lag_seconds,
          source_lag_seconds: data_lag_seconds
        }
      end

      def latest_time(source, field)
        columns = source.emits.schema_def&.column_names || []
        return nil if field && !columns.include?(field)

        Muni::Store.source_latest_time(source.slug, source, hall: source.hall, time_field: field)
      rescue StandardError
        nil
      end

      def source_mode(source_slug)
        return SOURCE_MODES[source_slug] if SOURCE_MODES.key?(source_slug)

        source = Muni::Registry.source(source_slug)
        return 'digest' if source&.digest_role
        return 'inventory' if source&.inventory_mode == :replace

        'delayed'
      end

      def source_completeness(mode)
        SOURCE_COMPLETENESS.fetch(mode, 'citywide_operational_feed')
      end

      def catalog_url(source_slug)
        source = Muni::Registry.source(source_slug)
        package = source&.catalog&.[](:package) || Array(source&.catalog&.[](:packages)).first
        package && "#{source.base_url}/dataset/#{package}"
      end

      def catalog_note(source_slug)
        source = Muni::Registry.source(source_slug)
        return nil unless source
        if source.inventory_mode == :replace
          return 'Official current inventory; replacement occurs only after a complete refresh.'
        end

        "Official source with #{source.retention_days}-day product retention." if source.retention_days
      end
    end
  end
end
