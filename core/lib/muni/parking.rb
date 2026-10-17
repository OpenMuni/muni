require 'muni/local_time'
require 'muni/helpers/geo'

module Muni
  # Normalization and advisory logic for metered parking inventory records.
  module Parking
    STATUS_LABELS = {
      paid_now:            'Paid now',
      outside_meter_hours: 'Outside meter hours',
      unknown_rules:       'Unknown rules'
    }.freeze
    STATUS_VALUES = STATUS_LABELS.values.freeze
    UNKNOWN = 'Unknown'.freeze
    DEFAULT_METER_DAYS = (1..6).to_a.freeze # Monday-Saturday when the source omits day text.

    module_function

    def parse_max_minutes(value)
      text = clean_text(value)
      return nil unless text

      match = text.match(/(\d+(?:\.\d+)?)\s*(hour|hours|hr|hrs|minute|minutes|min)\b/i)
      return nil unless match

      amount = match[1].to_f
      unit = match[2].downcase
      minutes = unit.start_with?('hour', 'hr') ? amount * 60 : amount
      minutes.round
    end

    def max_time_label(minutes)
      minutes = integer_or_nil(minutes)
      return UNKNOWN unless minutes&.positive?
      return '30 min' if minutes == 30
      return '1 hour' if minutes == 60

      hours = minutes / 60.0
      hours == hours.to_i ? "#{hours.to_i} hours" : "#{minutes} min"
    end

    def parse_rate(value)
      text = clean_text(value)
      return nil unless text

      cleaned = text.gsub(/[^0-9.]/, '')
      return nil if cleaned.empty?

      Float(cleaned)
    rescue ArgumentError
      nil
    end

    def rate_label(rate)
      rate = float_or_nil(rate)
      return UNKNOWN unless rate&.positive?

      dollars = rate == rate.to_i ? rate.to_i.to_s : format('%.2f', rate)
      "$#{dollars}/hr"
    end

    def parse_minutes_per_payment(value)
      float_or_nil(value)
    end

    def rule_status(max_minutes:, hourly_rate:, operation_hours:)
      max_minutes && hourly_rate&.positive? && operation_rule(operation_hours) ? 'rules_known' : 'unknown_rules'
    end

    def normalize_operation_window(value)
      text = clean_text(value)
      return UNKNOWN unless text

      rule = operation_rule(text)
      return compact_hours_text(text) unless rule

      "#{clock_label(rule[:start_minute])}-#{clock_label(rule[:end_minute])}#{day_suffix(rule[:days])}"
    end

    def operation_rule(value)
      text = clean_text(value)
      return nil unless text

      pair = parse_time_pair(text)
      return nil unless pair

      {
        start_minute: pair[0],
        end_minute:   pair[1],
        days:         days_for(text)
      }
    end

    def status_key(row, at: Time.now.utc)
      return :unknown_rules unless known_rules?(row)

      operation_active?(row, at: at) ? :paid_now : :outside_meter_hours
    end

    def status_label(row, at: Time.now.utc)
      STATUS_LABELS.fetch(status_key(row, at: at))
    end

    def operation_active?(row, at: Time.now.utc)
      rule = operation_rule(value(row, :operation_hours))
      return false unless rule

      local = Muni::LocalTime.local_time(at, city: value(row, :hall) || 'cambridge')
      return false unless rule[:days].include?(local.wday)

      current = (local.hour * 60) + local.min
      within_window?(current, rule[:start_minute], rule[:end_minute])
    end

    def known_rules?(row)
      value(row, :rule_status).to_s == 'rules_known' ||
        (integer_or_nil(value(row, :max_minutes)) &&
         float_or_nil(value(row, :hourly_rate))&.positive? &&
         operation_rule(value(row, :operation_hours)))
    end

    def status_payload(row, at: Time.now.utc)
      key = status_key(row, at: at)
      {
        'meter_status'     => STATUS_LABELS.fetch(key),
        'meter_status_key' => key.to_s
      }
    end

    def estimate(row, duration_minutes:, at: Time.now.utc)
      requested = (integer_or_nil(duration_minutes) || 0).clamp(0, 24 * 60)
      max_allowed = integer_or_nil(value(row, :max_minutes))
      capped = max_allowed&.positive? ? [requested, max_allowed].min : requested
      rate = float_or_nil(value(row, :hourly_rate))
      active = billable_minutes(row, duration_minutes: capped, at: at)
      cost = rate && active ? ((active / 60.0) * rate).round(2) : nil

      {
        requested_minutes:         requested,
        priced_duration_minutes:   capped,
        billable_minutes:          active,
        estimated_cost:            cost,
        exceeds_max_time:          max_allowed&.positive? ? requested > max_allowed : nil,
        max_allowed_minutes:       max_allowed,
        max_allowed_minutes_label: max_time_label(max_allowed)
      }
    end

    def billable_minutes(row, duration_minutes:, at: Time.now.utc)
      return nil unless known_rules?(row)

      minutes = (integer_or_nil(duration_minutes) || 0).clamp(0, 24 * 60)
      (0...minutes).count { |offset| operation_active?(row, at: at + (offset * 60)) }
    end

    def geometry_contains?(row, lon, lat)
      geometry = value(row, :geometry)
      geometry.is_a?(Hash) && Muni::Helpers::Geo.boundary_contains?(geometry, lon, lat)
    end

    def distance_meters(row, lon, lat)
      coords = value(row, :location)
      return nil unless coords.is_a?(Array) && coords.length >= 2

      Muni::Helpers::Geo.distance_meters(lat, lon, coords[1], coords[0])
    end

    def clean_text(value)
      text = value.to_s.tr("\u00A0", ' ').gsub(/\s+/, ' ').strip
      text.empty? ? nil : text
    end

    def compact_hours_text(value)
      clean_text(value).to_s
                       .gsub(/[–—]/, '-')
                       .gsub(/\s*-\s*/, '-')
                       .gsub(/\b(am|pm)\b/i, &:upcase)
    end

    def parse_time_pair(value)
      text = clean_text(value)&.gsub(/[–—]/, '-')
      return nil unless text

      match = text.match(
        /(\d{1,2})(?::(\d{2}))?\s*([ap]\.?m\.?)?\s*(?:-|to)\s*
         (\d{1,2})(?::(\d{2}))?\s*([ap]\.?m\.?)?/ix
      )
      return nil unless match

      start_minute = clock_minutes(match[1], match[2], match[3], role: :start, other_hour: match[4].to_i)
      end_minute = clock_minutes(match[4], match[5], match[6], role: :end, other_hour: match[1].to_i)
      return nil unless start_minute && end_minute

      [start_minute, end_minute]
    end

    def clock_minutes(hour_text, minute_text, meridiem, role:, other_hour:)
      hour = hour_text.to_i
      minute = minute_text.to_s.empty? ? 0 : minute_text.to_i
      return nil unless hour.between?(1, 12) && minute.between?(0, 59)

      meridian = inferred_meridian(hour, meridiem, role: role, other_hour: other_hour)
      hour %= 12
      hour += 12 if meridian == 'PM'
      (hour * 60) + minute
    end

    def inferred_meridian(hour, meridiem, role:, other_hour:)
      text = meridiem.to_s.downcase.delete('.')
      return 'AM' if text == 'am'
      return 'PM' if text == 'pm'

      return 'AM' if role == :start && hour.between?(7, 11)
      return 'PM' if role == :start
      return 'PM' if role == :end && other_hour <= hour

      'PM'
    end

    def days_for(text)
      normalized = text.to_s.downcase.gsub(/\s+/, '')
      return (0..6).to_a if normalized.include?('daily')
      return (1..5).to_a if normalized.include?('mon-fri') || normalized.include?('exceptsaturday')
      return (1..6).to_a if normalized.include?('mon-sat')

      DEFAULT_METER_DAYS
    end

    def day_suffix(days)
      case days
      when (1..5).to_a then ' (Mon-Fri)'
      when (1..6).to_a then ''
      when (0..6).to_a then ' (Daily)'
      else ''
      end
    end

    def clock_label(minutes)
      hour = minutes / 60
      minute = minutes % 60
      suffix = hour >= 12 ? 'PM' : 'AM'
      hour %= 12
      hour = 12 if hour.zero?
      minute.zero? ? "#{hour} #{suffix}" : "#{hour}:#{minute.to_s.rjust(2, '0')} #{suffix}"
    end

    def within_window?(current, start_minute, end_minute)
      return true if start_minute == end_minute

      if start_minute < end_minute
        current >= start_minute && current < end_minute
      else
        current >= start_minute || current < end_minute
      end
    end

    def value(row, key)
      return row.public_send(key) if row.respond_to?(key)
      return nil unless row.respond_to?(:[])

      row[key] || row[key.to_s]
    end

    def integer_or_nil(value)
      return nil if value.nil? || value.to_s.strip.empty?

      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def float_or_nil(value)
      return nil if value.nil? || value.to_s.strip.empty?

      Float(value)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
