require_relative '_shared'
require 'digest'

module Cambridge
  class VisionZeroCrashes < Muni::Source
    include Cambridge::SharedSoda

    source :vision_zero_crashes,
           hall:     'cambridge',
           emits:    Muni::Records::Crash,
           base_url: SharedSoda::BASE_URL,
           auth:     :app_token

    RESOURCE = ENV.fetch('CAMBRIDGE_CRASHES_RESOURCE', 'gb5w-yva3').freeze
    SELECT = [
      ':id',
      'date_time',
      'day_of_week',
      'object_1',
      'object_2',
      'street_number',
      'street_name',
      'cross_street',
      'near_street',
      'location',
      'may_involve_cyclist',
      'may_involve_pedestrian',
      'manner_of_collision',
      'first_harmful_event',
      'p1_role',
      'p1_injury',
      'p1_non_motorist_desc',
      'p2_role',
      'p2_injury',
      'p2_non_motorist_desc'
    ].join(',').freeze

    def pull(since: nil, limit: 1_000)
      cursor = bounded_since(since, days: 90)
      where = "date_time >= '#{soql_since(cursor)}'"
      rows = socrata.query(resource: RESOURCE, where: where,
                           order: 'date_time DESC', limit: limit, select: SELECT)
      rows.map { |r| normalize(r) }
    end

    def cursor_time(record)
      record.occurred_at
    end

    private

    def normalize(row)
      emit(
        external_id:          external_id(row),
        hall:                 'cambridge',
        crash_type:           clean_string(row['most_severe_injury'] || row['crash_severity'] || crash_type(row)),
        injury:               injury?(row),
        fatal:                fatal?(row),
        cyclist:              truthy?(row['may_involve_cyclist']) || non_motorist?(row, 'BICYCLIST'),
        pedestrian:           truthy?(row['may_involve_pedestrian']) || non_motorist?(row, 'PEDESTRIAN'),
        manner:               clean_string(row['manner_of_collision']),
        first_harmful_event:  clean_string(row['first_harmful_event']),
        day_of_week:          clean_string(row['day_of_week']),
        location_description: location_description(row),
        location:             point(row),
        occurred_at:          Muni::Helpers::Normalize.parse_time(row['date_time']),
        source_url:           dataset_url
      )
    end

    def external_id(row)
      id = row[':id'] || row['crash_number'] || row['crash_id'] || row['_id']
      return id.to_s unless id.to_s.empty?

      fields = row.values_at('date_time', 'street_number', 'street_name', 'cross_street',
                             'object_1', 'object_2', 'manner_of_collision')
      "crash/#{Digest::SHA256.hexdigest(fields.join('|'))[0, 16]}"
    end

    def crash_type(row)
      event = clean_string(row['first_harmful_event'])
      return event if event

      [row['object_1'], row['object_2']].map { |v| clean_string(v) }.compact.join(' / ')
    end

    def point(row)
      coords = geometry_coords(row['coordinates']) || geometry_coords(row['location'])
      return Muni::Helpers::Geo.point(coords[0], coords[1]) if coords

      Muni::Helpers::Geo.point(row['longitude'], row['latitude'])
    end

    def geometry_coords(value)
      location_coords(value)
    end

    def truthy?(value)
      %w[Y y true 1 t Yes YES].include?(value.to_s.strip)
    end

    def injury?(row)
      injury_values(row).any? do |value|
        text = value.to_s.upcase
        text.include?('INJURY') && !text.include?('NO APPARENT')
      end
    end

    def fatal?(row)
      injury_values(row).any? { |value| value.to_s.upcase.include?('FATAL') }
    end

    def injury_values(row)
      row.values_at('injury_indicator', 'fatal_indicator', 'p1_injury', 'p2_injury')
    end

    def non_motorist?(row, kind)
      row.values_at('p1_non_motorist_desc', 'p2_non_motorist_desc')
         .any? { |value| value.to_s.upcase.include?(kind) }
    end

    def location_description(row)
      parts = [row['street_number'], row['street_name'], row['cross_street'], row['near_street']]
              .map { |value| clean_string(value) }
              .compact
      return parts.join(' / ') unless parts.empty?

      loc = row['location']
      return clean_string(loc) unless loc.is_a?(Hash)

      raw_address = loc['human_address']
      return nil unless raw_address

      clean_string(raw_address)
    end

    def dataset_url
      "#{SharedSoda::BASE_URL}/Public-Safety/Police-Department-Crash-Data-Updated/#{RESOURCE}"
    end
  end
end
