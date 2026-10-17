require_relative '_shared'
require 'muni/parking'

module Cambridge
  class MeteredParkingSpaces < Muni::Source
    include Cambridge::SharedSoda

    source :metered_parking_spaces,
           hall:     'cambridge',
           emits:    Muni::Records::MeteredParkingSpace,
           base_url: SharedSoda::BASE_URL,
           auth:     :app_token

    RESOURCE = ENV.fetch('CAMBRIDGE_METERED_PARKING_SPACES_RESOURCE', 'kvrt-t8v3').freeze
    SELECT = %w[
      space_id
      pbyp_zone
      maxtime
      minutesper
      rate
      operationh
      smartmeter
      the_geom
    ].join(',').freeze

    def pull(since: nil, limit: 5_000) # rubocop:disable Lint/UnusedMethodArgument
      rows = socrata.query(
        resource: RESOURCE,
        select:   SELECT,
        where:    'space_id IS NOT NULL AND the_geom IS NOT NULL',
        order:    'space_id ASC',
        limit:    limit
      )
      rows.filter_map { |row| normalize(row) }
    end

    private

    def normalize(row)
      space_id = clean_string(row['space_id'])
      geometry = row['the_geom']
      location = Muni::Helpers::Geo.centroid(geometry)
      return nil unless space_id && geometry.is_a?(Hash) && location

      max_minutes = Muni::Parking.parse_max_minutes(row['maxtime'])
      hourly_rate = Muni::Parking.parse_rate(row['rate'])
      operation_hours = clean_string(row['operationh'])

      emit(
        external_id:         "metered-parking/#{space_id}",
        hall:                'cambridge',
        space_id:            space_id,
        pay_by_phone_zone:   clean_string(row['pbyp_zone']),
        max_minutes:         max_minutes,
        max_time_label:      Muni::Parking.max_time_label(max_minutes),
        hourly_rate:         hourly_rate,
        rate_label:          Muni::Parking.rate_label(hourly_rate),
        minutes_per_payment: Muni::Parking.parse_minutes_per_payment(row['minutesper']),
        operation_hours:     operation_hours,
        operation_window:    Muni::Parking.normalize_operation_window(operation_hours),
        rule_status:         Muni::Parking.rule_status(
          max_minutes:     max_minutes,
          hourly_rate:     hourly_rate,
          operation_hours: operation_hours
        ),
        smart_meter:         clean_string(row['smartmeter']),
        location:            location,
        geometry:            geometry,
        source_url:          dataset_url
      )
    end

    def dataset_url
      "#{SharedSoda::BASE_URL}/Transportation/Metered-Parking-Spaces/#{RESOURCE}"
    end
  end
end
