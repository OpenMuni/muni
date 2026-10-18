require 'time'
require 'uri'

module Muni
  # Public status contract for lightweight city health pages.
  # rubocop:disable-next Metrics/ModuleLength
  module Status
    module_function

    SCHEMA_VERSION = 1
    CRITICAL_SOURCES = %w[
      cambridge/service_requests
    ].freeze
    MODE_ORDER = {
      'live'                  => 0,
      'delayed'               => 1,
      'digest'                => 2,
      'representative_sensor' => 3,
      'inventory'             => 4,
      'experimental'          => 5
    }.freeze
    SOURCE_LABELS = {
      'cambridge/service_requests'           => '311 service requests',
      'cambridge/police_log'                 => 'Police daily log',
      'cambridge/crime_reports'              => 'Crime reports',
      'cambridge/dispatch_calls'             => 'Dispatch calls',
      'cambridge/building_permits'           => 'Building permits',
      'cambridge/new_construction_permits'   => 'New construction permits',
      'cambridge/development_log'            => 'Development projects',
      'cambridge/zoning_appeals'             => 'Zoning appeals',
      'cambridge/vision_zero_crashes'        => 'Vision Zero crashes',
      'cambridge/cpd_crash_log'              => 'Recent crash log',
      'cambridge/traffic_volume_daily'       => 'Traffic volume counts',
      'cambridge/bicycle_counts'             => 'Bicycle counts',
      'cambridge/pedestrian_counts'          => 'Pedestrian counts',
      'cambridge/tree_inventory'             => 'Tree inventory',
      'cambridge/metered_parking_spaces'     => 'Metered parking spaces',
      'cambridge/city_calendar'              => 'City calendar',
      'cambridge/tourism_events'             => 'Tourism events',
      'cambridge/primegov_meetings'          => 'PrimeGov meetings',
      'cambridge/city_news'                  => 'City news',
      'cambridge/cambridge_life'             => 'Cambridge Life',
      'cambridge/cambridge_day'              => 'Cambridge Day',
      'cambridge/construction_highlights'    => 'Construction highlights',
      'cambridge/city_construction_projects' => 'City construction projects',
      'cambridge/practical_services'         => 'Practical services'
    }.freeze

    def snapshot(hall: 'cambridge')
      now = Time.now.utc
      hall_obj = Muni::Hall.find(hall)
      return outage_snapshot(hall, now, 'Unknown city.') unless hall_obj

      counts = Muni::Store.counts_by_source(hall: hall)
      sources = source_rows(hall, counts, now)
      checks = status_checks(hall, counts, sources, now)
      status = overall_status(checks, sources)
      {
        schema_version: SCHEMA_VERSION,
        version:        Muni::VERSION,
        hall:           hall,
        name:           hall_obj.name,
        generated_at:   iso_time(now),
        overall_status: status,
        summary:        summary(status, checks, sources),
        checks:         checks,
        sources:        sources,
        backup:         Backup.snapshot(now: now),
        water:          Muni::Water.enabled? ? Muni::Water::Query.new(now: now).coverage : [],
        metrics:        metrics(counts, sources)
      }
    rescue StandardError
      outage_snapshot(hall, Time.now.utc, 'Status snapshot could not be generated.')
    end

    def source_rows(hall, counts, now)
      source_slugs = Muni::Registry.sources.keys.select { |slug| slug.start_with?("#{hall}/") }
      source_slugs
        .map { |slug| source_row(slug, counts.fetch(slug, 0), now) }
        .sort_by { |row| [MODE_ORDER.fetch(row[:source_mode], 99), row[:label]] }
    end

    def source_row(source_slug, row_count, now)
      source = Muni::Registry.source(source_slug)
      latest_run = Muni::Store.latest_beat_run(source_slug)
      latest_success = Muni::Store.latest_beat_run(source_slug, successful: true)
      data = Muni::Dashboard.source_data_freshness(source_slug)
      mode = Muni::Dashboard.source_mode(source_slug)
      row = {
        source:                 source_slug,
        label:                  source_label(source_slug),
        source_mode:            mode,
        completeness:           Muni::Dashboard.source_completeness(mode),
        row_count:              row_count,
        critical:               critical_source?(source_slug),
        cadence:                Muni::Registry.beat(source_slug)&.every,
        status:                 'operational',
        reason:                 nil,
        last_run_at:            iso_time(latest_run&.[](:ended_at)),
        last_success_at:        iso_time(latest_success&.[](:ended_at)),
        last_seen_at:           iso_time(Muni::Store.last_seen(source_slug)),
        last_checked_at:        iso_time(Muni::Store.last_checked(source_slug)),
        latest_data_at:         iso_time(data[:latest_data_at]),
        last_collected_at:      iso_time(data[:last_collected_at]),
        data_lag_seconds:       data[:data_lag_seconds],
        collection_lag_seconds: latest_success ? [(now - parse_time(latest_success[:ended_at])).to_i, 0].max : nil,
        last_error:             public_error(latest_run&.[](:error)),
        note:                   Muni::Dashboard::SourceStatus::SOURCE_NOTES[source_slug] ||
                                Muni::Dashboard.catalog_note(source_slug),
        source_url:             Muni::Dashboard.catalog_url(source_slug)
      }
      row.merge(evaluate_source(row, source))
    end

    # rubocop:disable-next Metrics/CyclomaticComplexity
    def evaluate_source(row, source)
      return status_for('outage', 'Critical source has no collected rows.') if row[:critical] && row[:row_count].zero?
      return status_for('degraded', 'No collected rows yet.') if row[:row_count].zero?
      return status_for('degraded', 'Latest collection run failed.') if row[:last_error]

      case row[:source_mode]
      when 'live'
        stale_status(row[:data_lag_seconds], live_max_lag_seconds, 'Live source data is stale.')
      when 'delayed'
        stale_status(row[:data_lag_seconds], delayed_max_lag_seconds, 'Delayed official feed is stale.')
      when 'digest'
        stale_status(row[:collection_lag_seconds], digest_max_collection_lag_seconds,
                     'Digest source has not collected recently.')
      when 'representative_sensor'
        stale_status(row[:collection_lag_seconds] || row[:data_lag_seconds], sensor_max_collection_lag_seconds,
                     'Representative sensor feed has not collected recently.')
      when 'inventory'
        status_for('operational', 'Inventory snapshot is available.')
      when 'experimental'
        status_for('operational', 'Experimental source is available.')
      else
        stale_status(row[:data_lag_seconds], live_max_lag_seconds, 'Source data is stale.')
      end
    rescue StandardError
      status_for(source ? 'degraded' : 'outage', 'Source status could not be evaluated.')
    end

    def status_checks(hall, counts, sources, now)
      [
        app_check,
        readiness_check(hall, counts, now),
        collection_check(sources),
        basemap_check
      ]
    end

    def app_check
      {
        key:    'app',
        label:  'Website',
        status: 'operational',
        detail: 'The Muni web application generated this status snapshot.'
      }
    end

    def readiness_check(hall, counts, now)
      expected = Muni::Get::Registry.category_source_slugs.select { |slug| slug.start_with?("#{hall}/") }
      missing = expected.reject { |slug| counts.fetch(slug, 0).positive? }
      stale_beats = Muni::Registry.beats.keys.select { |slug| slug.start_with?("#{hall}/") }
                                  .reject { |slug| beat_fresh?(slug, now) }
      failures = missing + stale_beats
      detail = if failures.empty?
                 'Launch readiness checks are passing.'
               else
                 'Some readiness checks need attention.'
               end
      {
        key:           'readiness',
        label:         'Readiness',
        status:        failures.empty? ? 'operational' : 'degraded',
        detail:        detail,
        failing_count: failures.length
      }
    end

    def collection_check(sources)
      degraded = sources.count { |source| source[:status] == 'degraded' }
      outages = sources.count { |source| source[:status] == 'outage' }
      status = if outages.positive?
                 'outage'
               elsif degraded.positive?
                 'degraded'
               else
                 'operational'
               end
      {
        key:            'data_collection',
        label:          'Data collection',
        status:         status,
        detail:         collection_detail(status, degraded, outages),
        degraded_count: degraded,
        outage_count:   outages
      }
    end

    def basemap_check
      mode = ENV.fetch('MUNI_BASEMAP_MODE', 'auto')
      pmtiles = pmtiles_ready?
      hosted = hosted_basemap_ready?
      ready = mode != 'pmtiles' || pmtiles || hosted
      {
        key:    'basemap',
        label:  'Maps',
        status: ready ? 'operational' : 'degraded',
        detail: ready ? 'Map tiles are configured.' : 'Strict PMTiles mode is configured, but tiles are unavailable.',
        mode:   mode
      }
    end

    def metrics(counts, sources)
      latest_success = sources.filter_map { |source| parse_time(source[:last_success_at]) }.max
      {
        total_sources:                 sources.length,
        operational_sources:           sources.count { |source| source[:status] == 'operational' },
        degraded_sources:              sources.count { |source| source[:status] == 'degraded' },
        outage_sources:                sources.count { |source| source[:status] == 'outage' },
        total_records:                 counts.values.sum,
        last_successful_collection_at: iso_time(latest_success)
      }
    end

    def overall_status(checks, sources)
      return 'outage' if checks.any? { |check| check[:status] == 'outage' }
      return 'outage' if sources.any? { |source| source[:critical] && source[:status] == 'outage' }
      return 'degraded' if checks.any? { |check| check[:status] == 'degraded' }
      return 'degraded' if sources.any? { |source| %w[degraded outage].include?(source[:status]) }

      'operational'
    end

    def summary(status, checks, sources)
      degraded_sources = sources.count { |source| source[:status] == 'degraded' }
      outage_sources = sources.count { |source| source[:status] == 'outage' }
      degraded_checks = checks.count { |check| check[:status] == 'degraded' }
      {
        label:            status_label(status),
        message:          status_message(status, degraded_sources, outage_sources, degraded_checks),
        degraded_sources: degraded_sources,
        outage_sources:   outage_sources,
        degraded_checks:  degraded_checks
      }
    end

    def outage_snapshot(hall, now, message)
      {
        schema_version: SCHEMA_VERSION,
        version:        Muni::VERSION,
        hall:           hall,
        generated_at:   iso_time(now),
        overall_status: 'outage',
        summary:        { label: 'Major outage', message: message },
        checks:         [{ key: 'status', label: 'Status', status: 'outage', detail: message }],
        sources:        [],
        metrics:        { total_sources: 0, total_records: 0 }
      }
    end

    def beat_fresh?(source_slug, now)
      beat = Muni::Registry.beat(source_slug)
      last = Muni::Store.latest_beat_run(source_slug, successful: true)
      ended_at = parse_time(last && last[:ended_at])
      beat && ended_at && (now - ended_at <= readiness_max_beat_age(beat))
    end

    def readiness_max_beat_age(beat)
      override = ENV.fetch('MUNI_READY_MAX_BEAT_AGE_SECONDS', nil).to_i
      return override if override.positive?

      beat.every_seconds + ENV.fetch('MUNI_READY_BEAT_GRACE_SECONDS', '10800').to_i
    end

    def live_max_lag_seconds
      ENV.fetch('MUNI_STATUS_LIVE_MAX_LAG_SECONDS') do
        ENV.fetch('MUNI_READY_MAX_SOURCE_LAG_SECONDS', '172800')
      end.to_i
    end

    def delayed_max_lag_seconds
      ENV.fetch('MUNI_STATUS_DELAYED_MAX_LAG_SECONDS', (14 * 86_400).to_s).to_i
    end

    def digest_max_collection_lag_seconds
      ENV.fetch('MUNI_STATUS_DIGEST_MAX_COLLECTION_LAG_SECONDS', (7 * 86_400).to_s).to_i
    end

    def sensor_max_collection_lag_seconds
      ENV.fetch('MUNI_STATUS_SENSOR_MAX_COLLECTION_LAG_SECONDS', (45 * 86_400).to_s).to_i
    end

    def stale_status(age, max_age, message)
      return status_for('degraded', 'No freshness timestamp is available.') unless age

      age > max_age ? status_for('degraded', message) : status_for('operational', 'Freshness is within range.')
    end

    def status_for(status, reason)
      { status: status, reason: reason }
    end

    def collection_detail(status, degraded, outages)
      case status
      when 'operational' then 'Collectors are within their expected windows.'
      when 'outage' then "#{outages} critical source#{'s' unless outages == 1} unavailable."
      else "#{degraded} source#{'s' unless degraded == 1} need attention."
      end
    end

    def status_message(status, degraded_sources, outage_sources, degraded_checks)
      case status
      when 'operational'
        'Muni is collecting and serving city data normally.'
      when 'outage'
        "#{outage_sources} source#{'s' unless outage_sources == 1} unavailable; public status is impaired."
      else
        "#{degraded_sources} source#{'s' unless degraded_sources == 1} and " \
        "#{degraded_checks} check#{'s' unless degraded_checks == 1} need attention."
      end
    end

    def status_label(status)
      {
        'operational' => 'Operational',
        'degraded'    => 'Degraded',
        'outage'      => 'Major outage'
      }.fetch(status, status.to_s.capitalize)
    end

    def source_label(source_slug)
      SOURCE_LABELS.fetch(source_slug) do
        source_slug.split('/').last.tr('_', ' ').split.map(&:capitalize).join(' ')
      end
    end

    def critical_source?(source_slug)
      source = Muni::Registry.source(source_slug)
      source&.criticality == :critical || CRITICAL_SOURCES.include?(source_slug)
    end

    def public_error(error)
      return nil if error.to_s.strip.empty?

      'latest collection failed'
    end

    def pmtiles_ready?
      url = ENV.fetch('MUNI_PMTILES_URL', '/tiles/muni.pmtiles')
      return true if url.start_with?('http://', 'https://')
      return false unless url.start_with?('/tiles/')

      relative = url.sub(%r{\A/tiles/?}, '')
      File.file?(File.join(ENV.fetch('MUNI_TILES_PATH') { File.join(Muni::Config.data_dir, 'tiles') }, relative))
    end

    def hosted_basemap_ready?
      %w[MUNI_MAP_STYLE MUNI_MAPTILER_KEY MUNI_MAP_TILES].any? { |key| ENV[key].to_s.strip != '' }
    end

    def https_url?(value)
      uri = URI.parse(value.to_s)
      uri.is_a?(URI::HTTPS) && !uri.host.to_s.empty?
    rescue URI::InvalidURIError
      false
    end

    def iso_time(value)
      parse_time(value)&.iso8601
    end

    def parse_time(value)
      return nil unless value
      return value.utc if value.respond_to?(:utc)

      Time.parse(value.to_s).utc
    end
  end
end

require 'muni/status/backup'
