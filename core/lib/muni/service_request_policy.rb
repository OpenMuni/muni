require 'date'

module Muni
  module ServiceRequestPolicy
    CLOSED_STATUSES = %w[closed resolved archived completed complete done fixed].freeze
    OPEN_STATUSES = %w[open opened new submitted received].freeze
    ACKNOWLEDGED_STATUSES = [
      'acknowledged',
      'in progress',
      'in_progress',
      'assigned',
      'investigating',
      'dispatched',
      'started'
    ].freeze
    PENDING_STATUSES = ['pending', 'needs reallocation', 'apply'].freeze
    CLOSED_VISIBLE_SECONDS = 3 * 24 * 60 * 60
    STALE_ACK_SECONDS = 14 * 24 * 60 * 60
    MAP_WINDOW_SECONDS = 30 * 24 * 60 * 60
    ACTIVE_STATUSES = (OPEN_STATUSES + ACKNOWLEDGED_STATUSES + PENDING_STATUSES +
      %w[active create submit reopened]).freeze

    class << self
      # These feeds publish ISO timestamps. Do not let Time.parse turn an
      # impossible calendar date into a different, apparently valid report.
      def reported_time(value, city: nil)
        pattern = /\A(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d):(\d\d)(\.\d+)?(Z|[+-]\d\d(?::?\d\d)?)?\z/
        match = pattern.match(value.to_s)
        return nil unless match

        year, month, day, hour, minute, second = match.captures.first(6).map(&:to_i)
        return nil unless Date.valid_date?(year, month, day) && hour < 24 && minute < 60 && second < 60

        text = value.to_s.sub(' ', 'T')
        return Time.iso8601(match[8] ? text : "#{text}Z").utc if match[8] || !city

        result = Muni::LocalTime.local_to_utc(year, month, day, hour, minute, second + match[7].to_f, city: city)
        return nil unless Muni::LocalTime.local_time(result, city: city).strftime('%Y-%m-%dT%H:%M:%S') == text[0, 19]

        result
      rescue ArgumentError
        nil
      end

      def enrich(attrs, now: Time.now.utc)
        data = symbolized(attrs)
        last_touched = last_touched_at(data)
        lifecycle = lifecycle_status(data, last_touched: last_touched, now: now)
        display = display_status(data, last_touched: last_touched, now: now)
        visible = map_eligible?(data, now: now)
        {
          reported_at:      data[:opened_at],
          display_status:   display,
          lifecycle_status: lifecycle,
          last_touched_at:  last_touched,
          map_visible:      visible
        }
      end

      def visible?(record, now: Time.now.utc)
        map_visible?(symbolized(record.respond_to?(:to_h) ? record.to_h : record), now: now)
      end

      # Map policy is deliberately separate from historical/list visibility.
      def map_eligible?(attrs, now: Time.now.utc)
        data = symbolized(attrs.respond_to?(:to_h) ? attrs.to_h : attrs)
        return false if %w[closed missing uncertain].include?(data[:lifecycle_source_state])

        reported = data[:opened_at]
        reported.is_a?(Time) && reported >= now - MAP_WINDOW_SECONDS && reported <= now &&
          !closed_record?(data) && ACTIVE_STATUSES.include?(normalize_status(data[:status]))
      end

      # A map color describes the source's current progress and update recency.
      # It never changes the authoritative open/active eligibility decision.
      def map_signal(attrs, now: Time.now.utc)
        data = symbolized(attrs.respond_to?(:to_h) ? attrs.to_h : attrs)
        return nil unless map_eligible?(data, now: now)

        touched = last_touched_at(data)
        return 'no_recent_update' if touched && touched <= now - STALE_ACK_SECONDS

        normalized = normalize_status(data[:status])
        return 'acknowledged' if acknowledged_status?(normalized)
        return 'open' if OPEN_STATUSES.include?(normalized) || %w[create submit reopened].include?(normalized)

        'other_active'
      end

      def display_status(attrs, last_touched: nil, now: Time.now.utc)
        data = symbolized(attrs)
        normalized = normalize_status(data[:status])
        touched = last_touched || last_touched_at(data)
        return 'closed' if closed_status?(normalized) || data[:closed_at]
        return 'stale' if acknowledged_status?(normalized) && stale?(touched, now: now)

        normalized.empty? ? 'open' : normalized
      end

      def lifecycle_status(attrs, last_touched: nil, now: Time.now.utc)
        data = symbolized(attrs)
        normalized = normalize_status(data[:status])
        touched = last_touched || last_touched_at(data)
        return 'closed' if closed_status?(normalized) || data[:closed_at]
        return 'stale' if acknowledged_status?(normalized) && stale?(touched, now: now)
        return 'acknowledged' if acknowledged_status?(normalized)
        return 'pending' if PENDING_STATUSES.include?(normalized)
        return 'open' if normalized.empty? || OPEN_STATUSES.include?(normalized)

        'pending'
      end

      private

      def map_visible?(data, now:)
        return true unless closed_record?(data)

        terminal = data[:closed_at] || data[:updated_at]
        terminal && terminal >= now - CLOSED_VISIBLE_SECONDS
      end

      def closed_record?(data)
        data[:closed_at] || closed_status?(normalize_status(data[:status]))
      end

      def closed_status?(status)
        CLOSED_STATUSES.include?(status)
      end

      def acknowledged_status?(status)
        ACKNOWLEDGED_STATUSES.include?(status)
      end

      def stale?(time, now:)
        time && time <= now - STALE_ACK_SECONDS
      end

      def last_touched_at(data)
        data[:updated_at] || data[:acknowledged_at] || data[:opened_at]
      end

      def normalize_status(value)
        value.to_s.downcase.strip.gsub(/\s+/, ' ')
      end

      def symbolized(attrs)
        attrs.each_with_object({}) do |(key, value), memo|
          memo[key.to_sym] = value
        end
      end
    end
  end
end
