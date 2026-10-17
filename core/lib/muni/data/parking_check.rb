require 'time'

module Muni
  module Data
    module ParkingCheck
      module_function

      def call(hall:, lat:, lon:, arrive_at: nil, duration_minutes: 60)
        Muni::Data.send(:require_hall!, hall)
        latitude = Float(lat)
        longitude = Float(lon)
        checked_at = parse_time(arrive_at) || Time.now.utc
        requested_duration = positive_duration(duration_minutes)
        rows = Muni::Store.query(Muni::Records::MeteredParkingSpace, hall: hall, limit: 5_000)
        match, confidence, distance = match_space(rows, longitude, latitude)
        estimate = estimate(match, requested_duration, checked_at)
        status_key = match ? Muni::Parking.status_key(match, at: checked_at) : nil
        warnings = warnings_for(match, confidence, estimate)

        response(
          hall: hall, latitude: latitude, longitude: longitude, checked_at: checked_at,
          requested_duration: requested_duration, match: match, confidence: confidence,
          distance: distance, estimate: estimate, status_key: status_key
        ).merge(warnings: warnings.uniq)
      rescue ArgumentError, TypeError
        raise Muni::Data::Error, 'lat and lon must be numeric'
      end

      def response(hall:, latitude:, longitude:, checked_at:, requested_duration:, match:, confidence:, distance:,
                   estimate:, status_key:)
        {
          hall:              hall,
          checked_at:        checked_at.utc.iso8601,
          input:             input(latitude, longitude, checked_at, estimate, requested_duration),
          confidence:        confidence,
          distance_meters:   distance&.round(1),
          meter_active:      meter_active(status_key),
          meter_status:      status_key && Muni::Parking::STATUS_LABELS.fetch(status_key),
          space:             match && space_payload(match, distance: distance, at: checked_at),
          estimate:          estimate,
          source_updated_at: source_updated_at(match)
        }
      end

      def input(latitude, longitude, checked_at, estimate, requested_duration)
        {
          lat:              latitude,
          lon:              longitude,
          arrive_at:        checked_at.utc.iso8601,
          duration_minutes: estimate[:requested_minutes] || requested_duration
        }
      end

      def parse_time(value)
        return nil if value.nil? || value.to_s.strip.empty?
        return value if value.is_a?(Time)

        Time.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def positive_duration(value)
        minutes = value.to_s.to_i
        minutes.positive? ? minutes : 60
      end

      def match_space(rows, lon, lat)
        inside = rows.find { |row| Muni::Parking.geometry_contains?(row, lon, lat) }
        return [inside, 'inside_space', 0.0] if inside

        nearest, distance = nearest_space(rows, lon, lat)
        return [nil, 'none', nil] unless nearest

        confidence = distance <= 35 ? 'nearby_space' : 'nearest_space'
        [nearest, confidence, distance]
      end

      def nearest_space(rows, lon, lat)
        candidates = rows.filter_map do |row|
          meters = Muni::Parking.distance_meters(row, lon, lat)
          meters && [row, meters]
        end
        candidates.min_by { |_, meters| meters }
      end

      def estimate(match, duration, checked_at)
        return {} unless match

        Muni::Parking.estimate(match, duration_minutes: duration, at: checked_at)
      end

      def meter_active(status_key)
        case status_key
        when :paid_now then true
        when :outside_meter_hours then false
        end
      end

      def space_payload(row, distance:, at:)
        Muni::Data.record_payload(row).except(:geometry).merge(
          meter_status:     Muni::Parking.status_label(row, at: at),
          meter_status_key: Muni::Parking.status_key(row, at: at).to_s,
          distance_meters:  distance&.round(1)
        )
      end

      def source_updated_at(match)
        Muni::Data.send(
          :iso_time,
          match&.last_seen_at || Muni::Store.last_seen('cambridge/metered_parking_spaces')
        )
      end

      def warnings_for(match, confidence, estimate)
        warnings = [
          'Parking guidance is advisory; always check posted signs, temporary restrictions, ' \
          'curb markings, and meter displays.',
          'This does not prove that a space is available or legal for your vehicle.'
        ]
        warnings << 'No metered parking space matched this location.' unless match
        if %w[nearby_space nearest_space].include?(confidence)
          warnings << 'Using the nearest metered space centroid, not a containing polygon.'
        end
        warnings << 'This space has incomplete meter rules in the source data.' if unknown_rules?(match)
        warnings << 'Requested duration exceeds the listed maximum stay.' if estimate[:exceeds_max_time]
        warnings
      end

      def unknown_rules?(match)
        match && !Muni::Parking.known_rules?(match)
      end
    end
  end
end
