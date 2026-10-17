require_relative '_shared'

module Boston
  class CrimeReports < Muni::Source
    include SharedCkan

    PACKAGE = 'crime-incident-reports-august-2015-to-date-source-new-system'.freeze
    RETENTION_DAYS = 730

    source :crime_reports,
           hall: 'boston', emits: Muni::Records::CrimeReport, base_url: SharedCkan::BASE_URL,
           domains: [:crime_reports], categories: %i[safety crime_reports], incident_kind: :crime,
           cadence: '12h', retention_days: RETENTION_DAYS,
           catalog: { package: PACKAGE }

    def each_record(since: nil, limit: nil, **)
      return enum_for(__method__, since: since, limit: limit, **) unless block_given?

      cutoff = [since, Time.now.utc - (RETENTION_DAYS * 86_400)].compact.max
      each_resource_row(package_id: PACKAGE, fields: %w[INCIDENT_NUMBER OCCURRED_ON_DATE],
                        where: %("OCCURRED_ON_DATE" >= '#{sql_time(cutoff)}'),
                        order: '"OCCURRED_ON_DATE" DESC', limit: limit,
                        changed_only: limit.nil?) { |row| yield normalize(row) }
    end

    def cursor_time(record) = record.reported_at || record.occurred_at

    def normalize(row)
      occurred = time(row['OCCURRED_ON_DATE'])
      emit(
        external_id: clean(row['INCIDENT_NUMBER'] || row['_id']) || raise(ArgumentError, 'crime row has no ID'),
        hall: 'boston', crime_category: clean(row['OFFENSE_DESCRIPTION'] || row['OFFENSE_CODE_GROUP']),
        crime_date_time: clean(row['OCCURRED_ON_DATE']), reporting_area: clean(row['REPORTING_AREA']),
        neighborhood: clean(row['DISTRICT']), location_description: clean(row['STREET']),
        location: row_point(row, lon: %w[Long], lat: %w[Lat]),
        occurred_at: occurred, reported_at: occurred, source_url: dataset_url(PACKAGE)
      )
    end
  end

  class VisionZeroCrashes < Muni::Source
    include SharedCkan

    CRASH_PACKAGE = 'vision-zero-crash-records'.freeze
    FATALITY_PACKAGE = 'vision-zero-fatality-records'.freeze
    RETENTION_DAYS = 730

    source :vision_zero_crashes,
           hall: 'boston', emits: Muni::Records::Crash, base_url: SharedCkan::BASE_URL,
           domains: [:crashes], categories: %i[safety crashes], incident_kind: :recent_crash,
           cadence: '1d', retention_days: RETENTION_DAYS,
           catalog: { packages: [CRASH_PACKAGE, FATALITY_PACKAGE] }

    def each_record(since: nil, limit: nil, **)
      return enum_for(__method__, since: since, limit: limit, **) unless block_given?

      cutoff = [since, Time.now.utc - (RETENTION_DAYS * 86_400)].compact.max
      remaining = limit
      read = each_resource_row(
        package_id: CRASH_PACKAGE, fields: %w[dispatch_ts mode_type],
        where: %("dispatch_ts" >= '#{sql_time(cutoff)}'), order: '"dispatch_ts" DESC',
        limit: remaining, changed_only: limit.nil?
      ) { |row| yield normalize_crash(row) }
      remaining -= read if remaining
      return if remaining && remaining <= 0

      each_resource_row(
        package_id: FATALITY_PACKAGE, fields: %w[date_time mode_type],
        where: %("date_time" >= '#{sql_time(cutoff)}'), order: '"date_time" DESC',
        limit: remaining, changed_only: limit.nil?
      ) { |row| yield normalize_fatality(row) }
    end

    def cursor_time(record) = record.occurred_at

    def normalize_crash(row)
      crash_record(row, prefix: 'crash', fatal: false, occurred: row['dispatch_ts'])
    end

    def normalize_fatality(row)
      crash_record(row, prefix: 'fatality', fatal: true, occurred: row['date_time'])
    end

    private

    def crash_record(row, prefix:, fatal:, occurred:)
      mode = clean(row['mode_type'])
      emit(
        external_id: "#{prefix}:#{clean(row['_id']) || stable_location_key(row, occurred)}", hall: 'boston',
        crash_type: mode, injury: !fatal, fatal: fatal,
        cyclist: mode.to_s.downcase.include?('bike') || mode.to_s.downcase.include?('cycl'),
        pedestrian: mode.to_s.downcase.include?('ped'), manner: clean(row['location_type']),
        location_description: crash_location(row), location: row_point(row, lon: %w[long], lat: %w[lat]),
        occurred_at: time(occurred), source_url: dataset_url(fatal ? FATALITY_PACKAGE : CRASH_PACKAGE)
      )
    end

    def crash_location(row)
      [row['street'], row['xstreet1'], row['xstreet2']].filter_map { |value| clean(value) }.uniq.join(' / ')
    end

    def stable_location_key(row, occurred)
      [occurred, row['street'], row['lat'], row['long']].join(':')
    end
  end
end
