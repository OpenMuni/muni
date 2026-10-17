require 'time'

module Muni
  module LocalTime
    DEFAULT_TIMEZONE = 'UTC'.freeze
    EASTERN_TIMEZONES = %w[America/New_York US/Eastern].freeze

    module_function

    def timezone_for(city)
      hall = city.respond_to?(:timezone) ? city : Muni::Hall.find(city.to_s)
      hall&.timezone || DEFAULT_TIMEZONE
    end

    def local_time(value, city:)
      time = time_value(value) || Time.now.utc
      timezone = timezone_for(city)

      case timezone
      when *EASTERN_TIMEZONES
        time.getlocal(eastern_dst?(time) ? '-04:00' : '-05:00')
      when 'UTC', 'Etc/UTC'
        time.utc
      else
        time.utc
      end
    end

    def local_iso8601(value, city:)
      local_time(value, city: city).iso8601
    end

    def local_to_utc(year, month, day, hour = 0, minute = 0, second = 0, city:)
      timezone = timezone_for(city)

      case timezone
      when *EASTERN_TIMEZONES
        offset = eastern_local_dst?(year, month, day, hour, minute, second) ? '-04:00' : '-05:00'
        Time.new(year, month, day, hour, minute, second, offset).utc
      when 'UTC', 'Etc/UTC'
        Time.utc(year, month, day, hour, minute, second)
      else
        Time.utc(year, month, day, hour, minute, second)
      end
    end

    def utc_iso8601(value)
      time_value(value)&.utc&.iso8601
    end

    def payload(value, city:)
      return nil unless value

      {
        local:    local_iso8601(value, city: city),
        utc:      utc_iso8601(value),
        timezone: timezone_for(city)
      }
    end

    def time_value(value)
      return nil if value.nil? || value.to_s.strip.empty?

      if value.is_a?(Time)
        return value.utc unless value.utc?

        return Time.utc(value.year, value.month, value.day, value.hour, value.min, value.sec + value.subsec)
      end
      return value.to_time.utc if value.respond_to?(:to_time)

      Time.parse(value.to_s).utc
    rescue ArgumentError, TypeError
      nil
    end

    def eastern_dst?(utc)
      year = utc.year
      utc >= us_dst_start_utc(year) && utc < us_dst_end_utc(year)
    end

    def us_dst_start_utc(year)
      # Second Sunday in March, 2:00 AM Eastern Standard Time.
      Time.utc(year, 3, nth_weekday_day(year, 3, 0, 2), 7)
    end

    def us_dst_end_utc(year)
      # First Sunday in November, 2:00 AM Eastern Daylight Time.
      Time.utc(year, 11, nth_weekday_day(year, 11, 0, 1), 6)
    end

    def eastern_local_dst?(year, month, day, hour = 0, minute = 0, second = 0)
      local = Time.utc(year, month, day, hour, minute, second)
      starts = Time.utc(year, 3, nth_weekday_day(year, 3, 0, 2), 2)
      ends = Time.utc(year, 11, nth_weekday_day(year, 11, 0, 1), 2)
      local >= starts && local < ends
    end

    def nth_weekday_day(year, month, weekday, nth)
      first = Time.utc(year, month, 1)
      1 + ((weekday - first.wday) % 7) + ((nth - 1) * 7)
    end
  end
end
