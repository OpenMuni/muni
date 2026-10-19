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
      def enrich(attrs, now: Time.now.utc)
        data = symbolized(attrs)
        last_touched = last_touched_at(data)
        lifecycle = lifecycle_status(data, last_touched: last_touched, now: now)
        display = display_status(data, last_touched: last_touched, now: now)
        visible = map_visible?(data, now: now)
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

      def map_eligible?(attrs, now: Time.now.utc)
        data = symbolized(attrs.respond_to?(:to_h) ? attrs.to_h : attrs)
        reported = data[:opened_at]
        reported.is_a?(Time) && reported.between?(now - MAP_WINDOW_SECONDS, now) &&
          !closed_record?(data) && ACTIVE_STATUSES.include?(normalize_status(data[:status]))
      end

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
        return 'stale' if acknowledged_status?(normalized) && stale?(touched, now: now)
        return 'closed' if closed_status?(normalized) || data[:closed_at]

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
