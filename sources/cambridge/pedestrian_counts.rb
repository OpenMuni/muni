require_relative '_shared'
require_relative 'location_resolver'
require 'digest'

module Cambridge
  class PedestrianCounts < Muni::Source
    include Cambridge::SharedSoda

    source :pedestrian_counts,
           hall:     'cambridge',
           emits:    Muni::Records::PedestrianCountDaily,
           base_url: SharedSoda::BASE_URL,
           auth:     :app_token

    RESOURCE = ENV.fetch('CAMBRIDGE_PEDESTRIAN_COUNTS_RESOURCE', '7zcp-kyfg').freeze

    def pull(since: nil, limit: 1_000)
      cursor = bounded_since(since, days: 1_095)
      where = "date >= '#{soql_since(cursor)}'"
      rows = socrata.query(resource: RESOURCE, where: where, order: 'date DESC', limit: limit)
      rows.map { |r| normalize(r) }
    end

    def cursor_time(record)
      record.observed_at
    end

    private

    def normalize(row)
      emit(
        external_id:  external_id(row),
        hall:         'cambridge',
        intersection: clean_string(row['intersection']),
        count:        integer(row['count']),
        location:     point(row),
        observed_at:  Muni::Helpers::Normalize.parse_time(row['date']),
        source_url:   dataset_url
      )
    end

    def external_id(row)
      fields = row.values_at('date', 'intersection')
      "ped-count/#{Digest::SHA256.hexdigest(fields.join('|'))[0, 20]}"
    end

    def point(row)
      label = clean_string(row['intersection'])
      return nil unless label

      resolver = @opts[:location_resolver] || (@location_resolver ||= Cambridge::LocationResolver.new)
      resolver.respond_to?(:call) ? resolver.call(label) : nil
    end

    def integer(value)
      value.to_f.to_i
    end

    def dataset_url
      "#{SharedSoda::BASE_URL}/d/#{RESOURCE}"
    end
  end
end
