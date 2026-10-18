require 'time'

module Muni
  module Apps
    module_function

    def manifest(hall:, digest: {}, reminders: [], calendar: [], health: {}, categories: [])
      hall_record = Muni::Hall.find(hall)
      [
        app('map', 'Map', 'map', 'City records on a live civic map.',
            href: "/?hall=#{hall}", count: sum_rows(categories), surface: 'primary'),
        app('transit', 'Transit', 'route', 'Real-time MBTA train radar, arrival boards, and performance.',
            href: "/transit?hall=#{hall}", surface: 'primary'),
        app('digest', 'Digest', 'newspaper', 'Latest city digest and trend cards.',
            href: "/digest?hall=#{hall}", count: Array(digest['cards']).length, surface: 'primary'),
        app('reminders', 'Reminders', 'bell', 'Practical city reminders and report follow-ups.',
            count: reminders.length, surface: 'agentic'),
        app('calendar', 'Calendar', 'calendar', 'Meetings, hearings, and civic events.',
            count: calendar.length, status: hall_record&.meetings_enabled? ? 'ready' : 'unavailable',
            surface: 'agentic'),
        app('health', 'Health', 'waveform.path.ecg', 'Municipal data, source, and service health.',
            status: health['status'] || health[:status] || 'unknown', surface: 'ops')
      ].compact
    end

    def health(source_freshness:, dashboard:)
      counts = source_counts(source_freshness)
      failed = failed_runs(source_freshness)
      record_count = counts.values.compact.sum(&:to_i)

      {
        'status'      => health_status(record_count, failed.length),
        'sources'     => source_health(counts: counts, record_count: record_count, failed: failed),
        'city_pulse'  => city_pulse(dashboard).compact,
        'source_runs' => {
          'failed' => failed.keys.sort
        }
      }
    end

    def reminders(hall:, limit: 8)
      rows = digest_items(hall, limit: 200)
      practical = rows.select do |row|
        row.item_type.to_s == 'service_reminder' || row.section_hint.to_s == 'practical_reminders'
      end
      meeting_prompts = rows.select do |row|
        row.item_type.to_s == 'public_meeting' && upcoming_time(row)
      end

      items = practical.first(5).map { |row| digest_card(row, kind: 'service_reminder') }
      items.concat(meeting_prompts.first(2).map { |row| digest_card(row, kind: 'civic_followup') })
      items.compact.first(limit)
    end

    def calendar(hall:, limit: 12)
      digest_calendar = digest_items(hall, limit: 300)
                        .select { |row| calendar_item?(row) }
                        .sort_by { |row| upcoming_time(row) || Time.at(0) }
                        .map { |row| digest_card(row, kind: row.item_type.to_s.empty? ? 'event' : row.item_type) }
      zoning = zoning_calendar(hall)
      (digest_calendar + zoning).sort_by { |row| parse_time(row['starts_at']) || Time.at(0) }.first(limit)
    end

    def app(id, title, icon, summary, href: nil, count: nil, requires_auth: false, status: 'ready', surface: 'primary')
      {
        'id'            => id,
        'title'         => title,
        'icon'          => icon,
        'summary'       => summary,
        'href'          => href,
        'count'         => count,
        'requires_auth' => requires_auth,
        'status'        => status,
        'surface'       => surface
      }.compact
    end

    def digest_items(hall, limit:)
      return [] unless Muni::Store.db.table_exists?(Muni::Records::DigestItem.table_name.to_sym)

      Muni::Store.query(Muni::Records::DigestItem, hall: hall, limit: limit)
    rescue Sequel::DatabaseError
      []
    end

    def digest_card(row, kind:)
      starts_at = row.event_start_at || row.published_at || row.updated_at || row.fetched_at
      {
        'id'          => row.external_id,
        'kind'        => kind,
        'title'       => row.title,
        'summary'     => row.summary,
        'category'    => row.category,
        'source'      => row.source_name || row.source_slug,
        'source_slug' => row.source_slug,
        'starts_at'   => iso_time(starts_at),
        'ends_at'     => iso_time(row.event_end_at),
        'location'    => row.location_name,
        'url'         => row.url
      }.compact
    end

    def calendar_item?(row)
      return true if row.event_start_at

      %w[event public_meeting hearing].include?(row.item_type.to_s)
    end

    def zoning_calendar(hall)
      return [] unless Muni::Store.db.table_exists?(Muni::Records::ZoningAppeal.table_name.to_sym)

      Muni::Store.query(Muni::Records::ZoningAppeal, hall: hall, limit: 50).filter_map do |row|
        next unless row.hearing_deadline_at

        zoning_card(row)
      end
    rescue Sequel::DatabaseError
      []
    end

    def upcoming_time(row)
      time = row.event_start_at || row.published_at
      return nil unless time

      time >= Time.now.utc - 86_400 ? time : nil
    end

    def health_status(record_count, failed_count)
      return 'degraded' if failed_count.positive?
      return 'warming' if record_count.zero?

      'ok'
    end

    def source_counts(source_freshness)
      hash_fetch(source_freshness, :counts) || {}
    end

    def failed_runs(source_freshness)
      latest_runs = hash_fetch(source_freshness, :latest_run) || {}
      latest_runs.select { |_, run| run.is_a?(Hash) && present?(run[:error] || run['error']) }
    end

    def source_health(counts:, record_count:, failed:)
      {
        'count'        => counts.length,
        'record_count' => record_count,
        'failed_count' => failed.length
      }
    end

    def city_pulse(dashboard)
      widgets = hash_fetch(dashboard, :widgets) || {}
      service_requests = hash_fetch(widgets, :service_requests) || {}
      safety = hash_fetch(widgets, :safety) || {}
      permits = hash_fetch(widgets, :permits) || {}
      crashes = hash_fetch(widgets, :crashes) || {}

      {
        'open_311_cases'     => service_requests[:open_cases] || service_requests['open_cases'],
        'stale_311_cases'    => service_requests[:stale_open_cases] || service_requests['stale_open_cases'],
        'opened_311_last_7d' => service_requests[:opened_last_7d] || service_requests['opened_last_7d'],
        'safety_items_30d'   => safety_items_count(safety),
        'permits_last_30d'   => permits[:permits_last_30d] || permits['permits_last_30d'],
        'collisions_window'  => crashes[:crashes_latest_window] || crashes['crashes_latest_window']
      }
    end

    def zoning_card(row)
      {
        'id'        => row.external_id,
        'kind'      => 'hearing_deadline',
        'title'     => "Zoning appeal: #{row.address || row.external_id}",
        'summary'   => row.relief,
        'category'  => 'zoning',
        'source'    => 'Board of Zoning Appeal',
        'starts_at' => iso_time(row.hearing_deadline_at),
        'location'  => row.address,
        'url'       => row.source_url
      }.compact
    end

    def safety_items_count(safety)
      %i[crime_reports_30d dispatch_calls_30d recent_crashes_30d].sum do |key|
        safety[key] || safety[key.to_s] || 0
      end
    end

    def sum_rows(categories)
      Array(categories).sum { |cat| (cat['row_count'] || cat[:row_count]).to_i }
    end

    def hash_fetch(hash, key)
      return nil unless hash.respond_to?(:[])

      hash[key] || hash[key.to_s]
    end

    def present?(value)
      !value.nil? && value.to_s.strip != ''
    end

    def iso_time(value)
      value.respond_to?(:utc) ? value.utc.iso8601 : value
    end

    def parse_time(value)
      return value if value.is_a?(Time)
      return nil if value.nil? || value.to_s.empty?

      Time.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
