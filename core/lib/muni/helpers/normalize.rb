require 'time'

module Muni
  module Helpers
    module Normalize
      module_function

      def parse_time(value)
        return value if value.is_a?(Time)
        return nil if value.nil?

        if value.is_a?(Numeric)
          sec = value > 1_000_000_000_000 ? value / 1000.0 : value.to_f
          return Time.at(sec).utc
        end

        s = value.to_s.strip
        return nil if s.empty?

        if s.match?(/\A\d+\z/)
          sec = s.to_i > 1_000_000_000_000 ? s.to_i / 1000.0 : s.to_i.to_f
          return Time.at(sec).utc
        end

        parsed = parse_us_slash_time(s)
        return parsed if parsed

        Time.rfc2822(s).utc
      rescue ArgumentError
        begin
          Time.parse(s).utc
        rescue ArgumentError
          nil
        end
      end

      def parse_us_slash_time(value)
        match = value.match(
          %r{
            \A(\d{1,2})/(\d{1,2})/(\d{4})
            (?:
              [ T]+(\d{1,2})(?::(\d{2}))?(?::(\d{2})(?:\.\d+)?)?\s*(AM|PM)?
              (?:\s*-\s*\d{1,2}(?::\d{2})?(?::\d{2})?\s*(?:AM|PM)?)?
            )?
            \z
          }ix
        )
        return nil unless match

        month = match[1].to_i
        day = match[2].to_i
        year = match[3].to_i
        hour = match[4].to_i
        min = match[5].to_i
        sec = match[6].to_i
        meridiem = match[7]&.upcase
        if meridiem == 'PM' && hour < 12
          hour += 12
        elsif meridiem == 'AM' && hour == 12
          hour = 0
        end

        Time.local(year, month, day, hour, min, sec).utc
      rescue ArgumentError
        nil
      end

      # ISO8601 with a Z suffix breaks SoQL/Postgres SQL filters on some APIs.
      def sql_timestamp(time)
        time.utc.strftime('%Y-%m-%dT%H:%M:%S')
      end

      def clean_address(str)
        return nil if str.nil?

        str.to_s.gsub(/\s+/, ' ').strip
      end

      # Convert cadence strings like '30s', '5m', '1h', '2d' into seconds.
      def parse_cadence(str)
        m = str.to_s.match(/\A(\d+)\s*([smhd])\z/)
        raise ArgumentError, "Invalid cadence #{str.inspect}" unless m

        n = m[1].to_i
        case m[2]
        when 's' then n
        when 'm' then n * 60
        when 'h' then n * 3600
        when 'd' then n * 86_400
        end
      end

      # Parse user-facing duration strings ('1h', '7d', '30m') for CLI args.
      def parse_duration(str)
        return nil if str.nil? || str.to_s.empty?

        parse_cadence(str)
      end
    end
  end
end
