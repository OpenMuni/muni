require 'securerandom'

module Muni
  module Water
    module ScheduleStore
      LEASE_SECONDS = 900
      BUSY_SECONDS = 30

      module_function

      def ensure_table!
        Storage.db.create_table?(:water_schedule_state) do
          String :source_slug, primary_key: true
          DateTime :next_run_at
          Integer :failure_count, default: 0
          String :lease_token
          DateTime :lease_expires_at
          DateTime :last_due_at
          DateTime :last_started_at
        end
        columns = Storage.db.schema(:water_schedule_state).map(&:first)
        %i[last_due_at last_started_at].each do |name|
          Storage.db.alter_table(:water_schedule_state) { add_column name, DateTime } unless columns.include?(name)
        end
      end

      def table = Storage.db[:water_schedule_state]

      def read(slug) = table.where(source_slug: slug).first

      def acquire(slug, now: Time.now.utc)
        Muni::Store.with_writer do
          table.db.transaction(mode: :immediate) do
            row = read(slug)
            return nil if row && row[:lease_token] && Water.time(row[:lease_expires_at]) > now
            return defer_busy(slug, now) if source_busy?(slug)

            token = SecureRandom.uuid
            values = { source_slug: slug, lease_token: token, lease_expires_at: now + LEASE_SECONDS,
                       last_due_at: (row && row[:next_run_at]) || now, last_started_at: now }
            table.insert_conflict(target: :source_slug, update: values.except(:source_slug)).insert(values)
            token
          end
        end
      end

      def complete(slug, token, next_run_at:, failure_count:, run_id: nil, next_trigger: nil)
        Muni::Store.with_writer do
          table.db.transaction do
            changed = table.where(source_slug: slug, lease_token: token)
                           .update(next_run_at: next_run_at, failure_count: failure_count,
                                   lease_token: nil, lease_expires_at: nil)
            RunTiming.complete(run_id, next_run_at, next_trigger) if changed.positive? && run_id
          end
        end
      end

      def renew(slug, token, now: Time.now.utc)
        Muni::Store.with_writer do
          table.where(source_slug: slug, lease_token: token).update(lease_expires_at: now + LEASE_SECONDS)
        end
      end

      def source_busy?(slug)
        path = "#{Muni::Config.db_path}.water-#{Water.hash(slug)[0, 16]}.lock"
        File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
          !lock.flock(File::LOCK_EX | File::LOCK_NB)
        ensure
          lock.flock(File::LOCK_UN)
        end
      end

      def defer_busy(slug, now)
        values = { source_slug: slug, lease_expires_at: now + BUSY_SECONDS }
        table.insert_conflict(target: :source_slug, update: values.except(:source_slug)).insert(values)
        nil
      end
    end

    class Schedule
      VERSION = 'water-calendar-v1'.freeze
      RETRY_DELAYS = [900, 3600, 14_400, 86_400].freeze

      def initialize(slug, definition)
        @slug = slug
        @definition = definition
      end

      def initial(now, last_ended_at = nil)
        saved = ScheduleStore.read(@slug)
        due = Water.time(saved && saved[:next_run_at])
        due ||= last_ended_at ? next_after(last_ended_at) : now
        [due, now].max
      end

      def next_after(now)
        now = now.getutc
        calendar = @definition[:calendar]
        return now + @definition[:cadence] unless calendar
        return next_minute(now, calendar[:minutes]) if calendar[:minutes]

        date = Clock.day(now)
        (0..7).each do |offset|
          day = date + offset
          next if calendar[:weekday] && day.wday != calendar[:weekday]

          candidate = Clock.eastern(day, calendar.fetch(:time))
          return candidate if candidate > now
        end
        raise Error, 'No calendar occurrence found'
      end

      def finish(now, error)
        previous = ScheduleStore.read(@slug)
        failures = error ? previous.to_h.fetch(:failure_count, 0).to_i + 1 : 0
        normal = next_after(now)
        if error && retryable?(error)
          retry_due = now + RETRY_DELAYS[[failures - 1, RETRY_DELAYS.length - 1].min]
          normal = [normal, retry_due].min
          normal = [normal, error.retry_at].max if error.respond_to?(:retry_at) && error.retry_at
        end
        { next_run_at: normal, failure_count: failures }
      end

      def snapshot
        { version: VERSION, calendar: @definition[:calendar], cadence_seconds: @definition[:cadence],
          timezone: @definition.dig(:calendar, :time) ? 'America/New_York' : 'UTC',
          retry_delays_seconds: RETRY_DELAYS }
      end

      def trigger(now, error, next_run_at)
        error && retryable?(error) && next_run_at != next_after(now) ? 'retry' : 'calendar'
      end

      private

      def retryable?(error)
        (error.respond_to?(:retryable?) && error.retryable?) || error.is_a?(Faraday::TimeoutError) ||
          error.is_a?(Faraday::ConnectionFailed)
      end

      def next_minute(now, minutes)
        hour = Time.utc(now.year, now.month, now.day, now.hour)
        [hour, hour + 3600].each do |base|
          minutes.sort.each do |minute|
            candidate = base + (minute * 60)
            return candidate if candidate > now
          end
        end
      end
    end
  end
end
