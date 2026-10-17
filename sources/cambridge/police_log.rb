require_relative '_shared'
require_relative 'location_resolver'
require 'digest'

module Cambridge
  class PoliceLog < Muni::Source
    include Cambridge::SharedSoda

    source :police_log,
           hall:     'cambridge',
           emits:    Muni::Records::PoliceLogEntry,
           base_url: SharedSoda::BASE_URL,
           auth:     :app_token

    RESOURCE = ENV.fetch('CAMBRIDGE_POLICE_LOG_RESOURCE', '3gki-wyrb').freeze

    def pull(since: nil, limit: 500)
      cursor = bounded_since(since, days: 30)
      where = "last_updated >= '#{soql_since(cursor)}'"
      rows = socrata.query(resource: RESOURCE, where: where, order: 'last_updated DESC', limit: limit)
      rows.map { |r| normalize(r) }
    end

    def cursor_time(record)
      record.reported_at || record.occurred_at
    end

    private

    def normalize(row)
      emit(
        external_id:       external_id(row),
        hall:              'cambridge',
        crime_category:    clean_string(row['type'] || row['crime'] || row['crime_category']),
        crime_subcategory: clean_string(row['subtype'] || row['crime_sub_category'] || row['offense_description']),
        description:       clean_string(row['description'] || row['narrative']),
        neighborhood:      clean_string(row['location'] || row['neighborhood']),
        location:          point(row),
        occurred_at:       Muni::Helpers::Normalize.parse_time(row['date_time'] || row['date_of_report']),
        reported_at:       Muni::Helpers::Normalize.parse_time(row['last_updated'] || row['date_reported']),
        source_url:        dataset_url
      )
    end

    def external_id(row)
      id = row['id'] || row['file_number'] || row['_id']
      return id.to_s unless id.to_s.empty?

      fields = row.values_at('date_time', 'type', 'subtype', 'location', 'description')
      "daily-log/#{Digest::SHA256.hexdigest(fields.join('|'))[0, 16]}"
    end

    def point(row)
      coords(row) || resolve_location(row)
    end

    def coords(row)
      loc = row['location'] || row['location_1']
      return nil unless loc.is_a?(Hash) && loc['coordinates']

      lon, lat = loc['coordinates']
      Muni::Helpers::Geo.point(lon, lat)
    end

    def resolve_location(row)
      label = row['location']
      return nil unless label.is_a?(String)

      resolver = @opts[:location_resolver] || (@location_resolver ||= Cambridge::LocationResolver.new)
      resolver.respond_to?(:call) ? resolver.call(label) : nil
    end

    def dataset_url
      "#{SharedSoda::BASE_URL}/Public-Safety/Daily-Police-Log/#{RESOURCE}"
    end
  end
end
