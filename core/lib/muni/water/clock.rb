module Muni
  module Water
    module Clock
      module_function

      # Explicit source offsets take precedence. Unqualified repeated/nonexistent
      # Eastern wall times cannot be silently assigned an instant.
      def eastern(date, clock = '00:00', zone: nil)
        parsed = Date.parse(date.to_s)
        # UTC is only a neutral carrier for the stated wall-clock components.
        # Parsing in the host timezone can normalize a nonexistent spring hour
        # before we can honor the source's explicit offset or reject ambiguity.
        wall = Time.parse("#{parsed} #{clock} UTC")
        if zone && %w[UTC GMT EST EDT].include?(zone.upcase)
          offset = { 'UTC' => '+00:00', 'GMT' => '+00:00', 'EST' => '-05:00', 'EDT' => '-04:00' }.fetch(zone.upcase)
          return Time.new(parsed.year, parsed.month, parsed.day, wall.hour, wall.min, wall.sec, offset).utc
        end
        validate_zone!(zone)
        spring = Muni::LocalTime.nth_weekday_day(parsed.year, 3, 0, 2)
        fall = Muni::LocalTime.nth_weekday_day(parsed.year, 11, 0, 1)
        ambiguous = (parsed.month == 11 && parsed.day == fall && wall.hour == 1) ||
                    (parsed.month == 3 && parsed.day == spring && wall.hour == 2)
        raise Error, 'Unresolved daylight-saving wall time' if ambiguous

        Muni::LocalTime.local_to_utc(parsed.year, parsed.month, parsed.day, wall.hour, wall.min, wall.sec,
                                     city: 'cambridge')
      end

      def validate_zone!(zone)
        return if zone.to_s.empty? || %w[America/New_York US/Eastern].include?(zone)

        raise Error, "Unsupported source timezone: #{zone}"
      end

      def day(time)
        Muni::LocalTime.local_time(time, city: 'cambridge').to_date
      end

      def bounds(date)
        [eastern(date), eastern(date + 1)]
      end
    end
  end
end
