require_relative '_shared'
require 'digest'

module Cambridge
  class CrimeReports < Muni::Source
    include Cambridge::SharedSoda

    source :crime_reports,
           hall:     'cambridge',
           emits:    Muni::Records::CrimeReport,
           base_url: SharedSoda::BASE_URL,
           auth:     :app_token

    RESOURCE = ENV.fetch('CAMBRIDGE_CRIME_REPORTS_RESOURCE', 'xuad-73uj').freeze

    def pull(since: nil, limit: 1_000)
      cursor = bounded_since(since, days: 365)
      where = "date_of_report >= '#{soql_since(cursor)}'"
      rows = socrata.query(resource: RESOURCE, where: where, order: 'date_of_report DESC', limit: limit)
      rows.map { |r| normalize(r) }
    end

    def cursor_time(record)
      record.reported_at || record.occurred_at
    end

    private

    def normalize(row)
      emit(
        external_id:          clean_string(row['file_number']) || external_id(row),
        hall:                 'cambridge',
        crime_category:       clean_string(row['crime']),
        crime_date_time:      clean_string(row['crime_date_time']),
        reporting_area:       clean_string(row['reporting_area']),
        neighborhood:         clean_string(row['neighborhood']),
        location_description: clean_string(row['location']),
        location:             point(row),
        occurred_at:          occurred_at(row),
        reported_at:          Muni::Helpers::Normalize.parse_time(row['date_of_report']),
        source_url:           dataset_url
      )
    end

    def external_id(row)
      fields = row.values_at('date_of_report', 'crime_date_time', 'crime', 'reporting_area', 'location')
      "crime/#{Digest::SHA256.hexdigest(fields.join('|'))[0, 16]}"
    end

    def occurred_at(row)
      raw = clean_string(row['crime_date_time'])
      return Muni::Helpers::Normalize.parse_time(row['date_of_report']) unless raw

      first = raw.split(/\s+-\s+/).first
      Muni::Helpers::Normalize.parse_time(first)
    rescue ArgumentError
      Muni::Helpers::Normalize.parse_time(row['date_of_report'])
    end

    def point(row)
      coords = location_coords(row['reporting_area_location'])
      return Muni::Helpers::Geo.point(coords[0], coords[1]) if coords

      Muni::Helpers::Geo.point(row['reporting_area_lon'], row['reporting_area_lat'])
    end

    def dataset_url
      "#{SharedSoda::BASE_URL}/d/#{RESOURCE}"
    end
  end
end
