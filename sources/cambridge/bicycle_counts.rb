require_relative '_shared'
require 'digest'

module Cambridge
  class BicycleCounts < Muni::Source
    include Cambridge::SharedSoda

    source :bicycle_counts,
           hall:     'cambridge',
           emits:    Muni::Records::BicycleCount,
           base_url: SharedSoda::BASE_URL,
           auth:     :app_token

    RESOURCE = ENV.fetch('CAMBRIDGE_BICYCLE_COUNTS_RESOURCE', 'ijm6-q7em').freeze

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
        external_id:       external_id(row),
        hall:              'cambridge',
        count_location:    clean_string(row['countlocation']),
        street:            clean_string(row['street']),
        traffic_direction: clean_string(row['trafficdirection']),
        cyclist_location:  clean_string(row['cyclistlocation']),
        cyclist_direction: clean_string(row['cyclistdirection']),
        movement_type:     clean_string(row['movementtype']),
        count:             integer(row['count']),
        temperature:       float(row['temperature']),
        weather:           clean_string(row['weather']),
        notes:             clean_string(row['notes']),
        node_number:       clean_string(row['nodenumber']),
        location:          point(row),
        observed_at:       observed_at(row),
        source_url:        dataset_url
      )
    end

    def external_id(row)
      fields = row.values_at('countlocation', 'date', 'time', 'trafficdirection', 'cyclistlocation',
                             'cyclistdirection', 'movementtype')
      "bike-count/#{Digest::SHA256.hexdigest(fields.join('|'))[0, 20]}"
    end

    def observed_at(row)
      date = clean_string(row['date'])
      time = clean_string(row['time'])
      return Muni::Helpers::Normalize.parse_time(date) unless date && time

      day = date.split('T').first
      Muni::Helpers::Normalize.parse_time("#{day}T#{time}")
    end

    def point(row)
      Muni::Helpers::Geo.point(row['longitude'], row['latitude'])
    end

    def integer(value)
      value.to_f.to_i
    end

    def float(value)
      Float(value)
    rescue ArgumentError, TypeError
      nil
    end

    def dataset_url
      "#{SharedSoda::BASE_URL}/d/#{RESOURCE}"
    end
  end
end
