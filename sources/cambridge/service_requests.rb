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
      record.opened_at
    end

    def lifecycle_lookup(stored)
      ids = stored.map { |row| row[:external_id] }
      raise ArgumentError, 'invalid Cambridge ticket ID' unless ids.all? { |id| /\A\d+\z/.match?(id) }

      where = "ticket_id in (#{ids.map { |id| "'#{id}'" }.join(',')})"
      rows = socrata.query(resource: RESOURCE, where: where, order: 'ticket_id ASC', limit: ids.length + 1)
      raise 'unexpected Cambridge identity' unless rows.all? { |row| ids.include?(row['ticket_id'].to_s) }
      raise 'duplicate Cambridge identities' unless rows.map { |row| row['ticket_id'] }.uniq.length == rows.length

      by_id = rows.to_h { |row| [row['ticket_id'].to_s, lifecycle_record(row)] }
      # SeeClickFix silently caps exact-ID responses at 20. Request at most 20
      # per call so absence cannot actually be an unrequested second page.
      ids.each_slice(20) do |batch_ids|
        live_lifecycle_rows(batch_ids).each { |raw| merge_live_lifecycle(by_id, raw) }
        sleep 0.25
      end
      by_id.values
    end

    def lifecycle_updates(state, limit:)
      field = 'ticket_last_updated_date_time'
      upper = state['upper'] || update_watermark(field)
      raise 'Cambridge update feed has no watermark' unless upper

      lower = state['lower'] || Muni::LocalTime.local_time(Time.now.utc - (30 * 86_400),
                                                           city: 'cambridge').strftime('%Y-%m-%dT%H:%M:%S')
      [upper, lower, state.dig('after', 0)].compact.each do |date|
        raise 'invalid source checkpoint date' unless /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?\z/.match?(date)
      end
      where = "#{field} >= '#{lower}' AND #{field} <= '#{upper}'"
      if state['after']
        stamp, id = state['after']
        raise 'invalid source checkpoint ID' unless /\A\d+\z/.match?(id)

        where += " AND (#{field} > '#{stamp}' OR (#{field} = '#{stamp}' AND ticket_id > '#{id}'))"
      end
      rows = socrata.query(resource: RESOURCE, where: where, order: "#{field} ASC, ticket_id ASC", limit: limit)
      validate_update_page!(rows, field, lower, upper, state['after'])

      checkpoint = { 'upper' => upper, 'lower' => lower,
                     'after' => rows.last && [rows.last.fetch(field), rows.last.fetch('ticket_id').to_s] }
      if rows.length < limit
        overlap = Time.iso8601("#{upper}Z") - (2 * 86_400)
        checkpoint = { 'lower' => overlap.strftime('%Y-%m-%dT%H:%M:%S'), 'after' => nil }
      end
      [corroborate_update_conflicts(rows), checkpoint]
    end

    private

    def corroborate_update_conflicts(rows)
      records = rows.map { |row| lifecycle_record(row) }
      conflicts = records.select do |record|
        record.closed_at && record.updated_at && record.updated_at > record.closed_at &&
          Muni::ServiceRequestPolicy::ACTIVE_STATUSES.include?(record.status.to_s.downcase)
      end
      return records if conflicts.empty?

      # A reopened older request must not wait for the slow all-record sweep
      # merely because the export retained its historical closure timestamp.
      checked = lifecycle_lookup(conflicts.map { |record| { external_id: record.external_id } })
                .to_h { |record| [record.external_id, record] }
      records.map { |record| checked.fetch(record.external_id, record) }
    end

    def update_watermark(field)
      socrata.query(resource: RESOURCE, select: "max(#{field}) AS watermark", limit: 1).first&.fetch('watermark')
    end

    def live_lifecycle_rows(ids)
      rows = http.get(OPEN311_PATH, { 'service_request_id' => ids.join(',') })
      valid = rows.is_a?(Array) && rows.all? { |row| ids.include?(row['service_request_id'].to_s) }
      valid &&= rows.map { |row| row['service_request_id'].to_s }.uniq.length == rows.length
      raise 'invalid Cambridge exact-ID response' unless valid

      rows
    end

    def corroborated_reopening?(previous, record)
      return false unless previous&.closed_at && record.updated_at

      active = Muni::ServiceRequestPolicy::ACTIVE_STATUSES
      active.include?(previous.status.to_s.downcase) && active.include?(record.status.to_s.downcase) &&
        record.updated_at > previous.closed_at &&
        (!previous.updated_at || record.updated_at >= previous.updated_at)
    end

    def merge_live_lifecycle(by_id, raw)
      record = normalize_open311(raw)
      previous = by_id[record.external_id]
      reopened = corroborated_reopening?(previous, record)
      newer_export = previous&.updated_at && (!record.updated_at || previous.updated_at >= record.updated_at)
      return if newer_export && !reopened && !live_closure_conflict?(previous, record)

      record.collected_at = record.last_seen_at = Time.now.utc
      record.lifecycle_evidence = { url: "#{OPEN311_BASE}/requests/#{record.external_id}.json",
                                   observed_at: record.collected_at.iso8601(6), raw: raw }
      if reopened
        record.lifecycle_evidence[:confirmed_reopened] = true
        record.lifecycle_evidence[:socrata] = previous.lifecycle_evidence
      end
      by_id[record.external_id] = record
    end

    def live_closure_conflict?(previous, record)
      closed_status?(record.status) && !closed_status?(previous&.status) &&
        (!record.updated_at || !previous&.updated_at || record.updated_at >= previous.updated_at)
    end

    def validate_update_page!(rows, field, lower, upper, after)
      keys = rows.map { |row| [row.fetch(field), row.fetch('ticket_id').to_s] }
      valid = keys.all? { |stamp, id| /\A\d+\z/.match?(id) && stamp >= lower && stamp <= upper }
      valid &&= keys.each_cons(2).all? { |left, right| (left <=> right).negative? }
      valid &&= !after || keys.empty? || (keys.first <=> after).positive?
      raise 'Cambridge update page is unordered or outside its checkpoint' unless valid
    end

    def lifecycle_record(row)
      record = normalize_socrata(row)
      record.collected_at = record.last_seen_at = Time.now.utc
      record.lifecycle_evidence = { url: "https://data.cambridgema.gov/resource/#{RESOURCE}.json?ticket_id=#{record.external_id}",
                                    observed_at: record.collected_at.iso8601(6), raw: row }
      record
    end

    def local_source_time(value)
      return nil if value.to_s.empty?
      return Muni::Helpers::Normalize.parse_time(value) if value.to_s.match?(/(?:Z|[+-]\d\d:\d\d)\z/)

      parsed = Time.iso8601("#{value}Z")
      Muni::LocalTime.local_to_utc(parsed.year, parsed.month, parsed.day, parsed.hour, parsed.min,
                                   parsed.sec + parsed.subsec, city: 'cambridge')
    rescue ArgumentError
      nil
    end

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
        opened_at:   Muni::ServiceRequestPolicy.reported_time(row['requested_datetime'], city: 'cambridge'),
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
        opened_at:       Muni::ServiceRequestPolicy.reported_time(row['ticket_created_date_time'], city: 'cambridge'),
        updated_at:      local_source_time(row['ticket_last_updated_date_time']),
        acknowledged_at: local_source_time(row['acknowledged_at']),
        closed_at:       local_source_time(row['ticket_closed_date_time']),
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
