require_relative '_shared'

module Cambridge
  class ServiceRequests < Muni::Source
    include Cambridge::SharedSoda

    OPEN311_BASE = ENV.fetch('CAMBRIDGE_OPEN311_BASE', 'https://seeclickfix.com/open311/v2/554').freeze
    OPEN311_PATH = 'requests.json'.freeze
    OPEN311_MIN_WINDOW_DAYS = 2
    OPEN311_BACKFILL_DAYS = 30

    source :service_requests,
           hall:     'cambridge',
           emits:    Muni::Records::ServiceRequest,
           base_url: OPEN311_BASE

    RESOURCE = ENV.fetch('CAMBRIDGE_SR_RESOURCE', '2z9k-mv9g').freeze

    def pull(since: nil, limit: 1_000)
      open311_rows(since: since, limit: limit).map { |r| normalize_open311(r) }
    rescue Muni::Helpers::Http::Error, Faraday::Error
      socrata_records(since: since, limit: limit)
    end

    def cursor_time(record)
      record.updated_at || record.opened_at
    end

    private

    def open311_rows(since:, limit:)
      rows = []
      page = 1
      loop do
        batch = Array(http.get(OPEN311_PATH, open311_params(since, page)))
        break if batch.empty?

        rows.concat(batch)
        break if limit && rows.size >= limit

        page += 1
      end
      limit ? rows.first(limit) : rows
    end

    def open311_params(since, page)
      {
        'start_date' => Muni::Helpers::Normalize.sql_timestamp(open311_since(since)),
        'end_date'   => Muni::Helpers::Normalize.sql_timestamp(Time.now.utc),
        'page'       => page
      }
    end

    def open311_since(since)
      floor = Time.now.utc - (OPEN311_MIN_WINDOW_DAYS * 86_400)
      backfill_floor = Time.now.utc - (OPEN311_BACKFILL_DAYS * 86_400)
      cursor = since ? [since, floor].min : backfill_floor
      [cursor, backfill_floor].max
    end

    def socrata_records(since:, limit:)
      cursor = bounded_since(since, days: OPEN311_BACKFILL_DAYS)
      where = "ticket_last_updated_date_time >= '#{soql_since(cursor)}'"
      rows = socrata.query(resource: RESOURCE, where: where,
                           order: 'ticket_last_updated_date_time DESC', limit: limit)
      rows.map { |r| normalize_socrata(r) }
    end

    def normalize_open311(row)
      status = clean_string(row['status'])
      updated_at = Muni::Helpers::Normalize.parse_time(row['updated_datetime'])
      emit(
        external_id: row['service_request_id'].to_s,
        hall:        'cambridge',
        case_type:   row['service_name'],
        status:      status_label(status),
        department:  row['agency_responsible'],
        description: clean_string(row['description']),
        address:     clean_string(row['address']),
        location:    Muni::Helpers::Geo.point(row['long'], row['lat']),
        opened_at:   Muni::Helpers::Normalize.parse_time(row['requested_datetime']),
        updated_at:  updated_at,
        closed_at:   closed_status?(status) ? updated_at : nil,
        image_url:   clean_string(row['media_url']),
        source_url:  "https://seeclickfix.com/issues/#{row['service_request_id']}"
      )
    end

    def normalize_socrata(row)
      emit(
        external_id:     (row['ticket_id'] || row['_id']).to_s,
        hall:            'cambridge',
        case_type:       row['issue_category'] || row['ticket_category'] || row['issue_type'],
        status:          row['ticket_status'],
        department:      row['department'],
        neighborhood:    row['neighborhood'],
        description:     row['ticket_description'] || row['issue_description'],
        address:         clean_string(row['address']),
        location:        point(row),
        opened_at:       Muni::Helpers::Normalize.parse_time(row['ticket_created_date_time']),
        updated_at:      Muni::Helpers::Normalize.parse_time(row['ticket_last_updated_date_time']),
        acknowledged_at: Muni::Helpers::Normalize.parse_time(row['acknowledged_at']),
        closed_at:       Muni::Helpers::Normalize.parse_time(row['ticket_closed_date_time']),
        image_url:       clean_string(row['image']),
        source_url:      source_url(row)
      )
    end

    def point(row)
      loc = row['location'] || {}
      if (coords = location_coords(loc))
        lon, lat = coords
        return Muni::Helpers::Geo.point(lon, lat)
      end

      lon = row['lng'] || row['longitude'] || loc['longitude']
      lat = row['lat'] || row['latitude'] || loc['latitude']
      Muni::Helpers::Geo.point(lon, lat)
    end

    def source_url(row)
      url = row['html_url'] || row['ticket_url']
      url.is_a?(Hash) ? url['url'] : url
    end

    def status_label(value)
      text = value.to_s.strip
      return nil if text.empty?

      text.split(/[\s_-]+/).map(&:capitalize).join(' ')
    end

    def closed_status?(value)
      %w[closed archived resolved].include?(value.to_s.downcase)
    end
  end
end
