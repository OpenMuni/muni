require_relative '_shared'

module Boston
  class ServiceRequests < Muni::Source
    include SharedCkan

    PACKAGE = '311-service-requests'.freeze
    RETENTION_DAYS = 365

    source :service_requests,
           hall: 'boston', emits: Muni::Records::ServiceRequest, base_url: SharedCkan::BASE_URL,
           domains: [:'311'], categories: %i[service_requests],
           cadence: '1d', retention_days: RETENTION_DAYS, criticality: :critical,
           catalog: { package: PACKAGE, schemas: %i[new_system legacy_year] }

    def each_record(since: nil, limit: nil, **)
      return enum_for(__method__, since: since, limit: limit, **) unless block_given?

      cutoff = [since, Time.now.utc - (RETENTION_DAYS * 86_400)].compact.max
      remaining = limit
      relevant_resources(cutoff).each do |resource|
        legacy = !resource['name'].to_s.match?(/NEW SYSTEM/i)
        date_field = legacy ? 'open_dt' : 'open_date'
        where = %("#{date_field}" >= '#{sql_time(cutoff)}')
        read = ckan.each_sql(resource: resource.fetch('id'), where: where,
                             order: %("#{date_field}" DESC), limit: remaining) do |row|
          yield legacy ? normalize_legacy(row) : normalize_new_system(row)
        end
        remaining -= read if remaining
        break if remaining && remaining <= 0
      end
    end

    def cursor_time(record)
      # This collector discovers newly opened requests. Lifecycle reconciliation
      # has an independent durable cursor and must not push discovery past rows.
      record.opened_at
    end

    def lifecycle_lookup(stored)
      resources = ckan.resources(PACKAGE, refresh: true)
      records = []
      groups = stored.group_by do |row|
        row[:external_id].start_with?('BCS-') ? 'new' : row[:opened_at]&.year.to_s
      end
      groups.each do |year, rows|
        resource = resources.find do |candidate|
          year == 'new' ? candidate['name'].to_s.match?(/NEW SYSTEM/i) : candidate['name'].to_s.match?(/\b#{year}\b/)
        end
        next unless resource && !year.empty?

        records.concat(lifecycle_resource_rows(resource, rows, year))
        verify_lifecycle_snapshot!(resource)
      end
      raise 'duplicate Boston identities' unless records.map(&:external_id).uniq.length == records.length

      records
    end

    def normalize_new_system(row)
      emit(
        external_id: case_id(row, 'case_id'), hall: 'boston',
        case_type: clean(row['service_name'] || row['case_topic']),
        status: status(row['case_status']),
        department: clean(row['assigned_department'] || row['assigned_team']),
        neighborhood: clean(row['neighborhood']),
        description: clean(row['closure_comments'] || row['closure_reason'] || row['case_topic']),
        address: clean(row['full_address']), location: row_point(row),
        opened_at: Muni::ServiceRequestPolicy.reported_time(row['open_date']),
        updated_at: time(row['close_date'] || row['open_date']),
        closed_at: time(row['close_date']), image_url: clean(row['submitted_photo']),
        source_url: dataset_url(PACKAGE)
      )
    end

    def normalize_legacy(row)
      emit(
        external_id: case_id(row, 'case_enquiry_id'), hall: 'boston',
        case_type: clean(row['type'] || row['case_title'] || row['reason']),
        status: status(row['case_status']), department: clean(row['department'] || row['queue']),
        neighborhood: clean(row['neighborhood']),
        description: clean(row['closure_reason'] || row['case_title'] || row['subject']),
        address: clean(row['location_street_name'] || row['location']), location: row_point(row),
        opened_at: Muni::ServiceRequestPolicy.reported_time(row['open_dt']),
        updated_at: time(row['closed_dt'] || row['open_dt']),
        closed_at: time(row['closed_dt']), image_url: clean(row['submitted_photo']),
        source_url: dataset_url(PACKAGE)
      )
    end

    private

    def time(value)
      # Legacy CKAN timestamps omit their offset. Preserve production's UTC
      # convention explicitly so reconciliation does not depend on the host TZ.
      return Muni::ServiceRequestPolicy.reported_time(value) unless /\A\d{4}-\d\d-\d\d\z/.match?(value.to_s)

      date = Date.iso8601(value)
      Time.utc(date.year, date.month, date.day)
    rescue ArgumentError
      nil
    end

    def verify_lifecycle_snapshot!(resource)
      current = ckan.resources(PACKAGE, refresh: true).find { |r| r['id'] == resource['id'] }
      return if current && ckan.resource_signature(current) == ckan.resource_signature(resource)

      raise 'Boston snapshot changed during lookup; retry batch'
    end

    def lifecycle_resource_rows(resource, rows, year)
      field = year == 'new' ? 'case_id' : 'case_enquiry_id'
      ids = rows.map { |row| row[:external_id] }
      raise ArgumentError, 'invalid Boston case ID' unless ids.all? { |id| /\A(?:BCS-)?\d+\z/.match?(id) }

      records = []
      where = %("#{field}" IN (#{ids.map { |id| "'#{id}'" }.join(',')}))
      ckan.each_sql(resource: resource.fetch('id'), where: where, order: '_id ASC', limit: ids.length + 1) do |raw|
        record = year == 'new' ? normalize_new_system(raw) : normalize_legacy(raw)
        raise 'unexpected Boston identity' unless ids.include?(record.external_id)

        record.source_revision_at = Time.iso8601("#{resource.fetch('last_modified')}Z")
        record.collected_at = record.last_seen_at = Time.now.utc
        record.lifecycle_evidence = { resource: resource['id'], revision: resource['last_modified'],
                                     url: "#{SharedCkan::BASE_URL}/dataset/#{PACKAGE}/resource/#{resource['id']}",
                                     observed_at: record.collected_at.iso8601(6), raw: raw }
        records << record
      end
      records
    end

    def relevant_resources(cutoff)
      years = (cutoff.year..Time.now.utc.year).to_a
      resources = ckan.resources(PACKAGE).select do |resource|
        name = resource['name'].to_s
        name.match?(/NEW SYSTEM/i) || years.any? { |year| name.match?(/\b#{year}\b/) }
      end
      resources.sort_by { |resource| resource['name'].to_s.match?(/NEW SYSTEM/i) ? 0 : 1 }
    end

    def case_id(row, field)
      clean(row[field] || row['_id']) || raise(ArgumentError, 'Boston 311 row has no case ID')
    end

    def status(value)
      text = clean(value)
      return unless text

      text.split(/[\s_-]+/).map(&:capitalize).join(' ')
    end
  end
end
