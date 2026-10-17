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
      record.updated_at || record.opened_at
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
        opened_at: time(row['open_date']), updated_at: time(row['close_date'] || row['open_date']),
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
        opened_at: time(row['open_dt']), updated_at: time(row['closed_dt'] || row['open_dt']),
        closed_at: time(row['closed_dt']), image_url: clean(row['submitted_photo']),
        source_url: dataset_url(PACKAGE)
      )
    end

    private

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
