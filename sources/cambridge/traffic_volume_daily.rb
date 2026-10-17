require_relative '_shared'
require_relative 'location_resolver'

module Cambridge
  class TrafficVolumeDaily < Muni::Source
    include Cambridge::SharedSoda

    source :traffic_volume_daily,
           hall:     'cambridge',
           emits:    Muni::Records::TrafficVolumeDaily,
           base_url: SharedSoda::BASE_URL,
           auth:     :app_token

    RESOURCE = ENV.fetch('CAMBRIDGE_TRAFFIC_VOLUME_RESOURCE', 'jwtp-n65u').freeze

    SELECT = [
      'date_trunc_ymd(timebin) as observed_on',
      'id',
      'intersection',
      'class',
      'sum(qty) as count'
    ].join(', ').freeze
    GROUP = 'date_trunc_ymd(timebin), id, intersection, class'.freeze

    def pull(since: nil, limit: 1_000)
      cursor = bounded_since(since, days: 10)
      where = "timebin >= '#{soql_since(cursor)}'"
      rows = socrata.query(resource: RESOURCE, where: where, select: SELECT, order: 'observed_on DESC',
                           limit: limit, offset: 0, group: GROUP)
      rows.map { |r| normalize(r) }
    end

    def cursor_time(record)
      record.observed_at
    end

    private

    def normalize(row)
      emit(
        external_id:     external_id(row),
        hall:            'cambridge',
        intersection_id: clean_string(row['id']),
        intersection:    clean_string(row['intersection']),
        vehicle_class:   clean_string(row['class']),
        count:           integer(row['count']),
        location:        point(row),
        observed_at:     Muni::Helpers::Normalize.parse_time(row['observed_on']),
        source_url:      dataset_url
      )
    end

    def external_id(row)
      day = clean_string(row['observed_on']).to_s.split('T').first
      ['traffic-volume', row['id'], day, row['class']].map { |v| clean_string(v) || 'unknown' }.join('/')
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
