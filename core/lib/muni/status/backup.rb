require_relative 'external_backup'

module Muni
  module Status
    # Reads retained maintenance metadata, never backup files or private paths.
    module Backup
      MAX_AGE_SECONDS = 26 * 3600
      DETAILS = {
        'current'  => 'A successful daily backup is recorded within the last 26 hours.',
        'overdue'  => 'The last recorded successful backup is more than 26 hours old.',
        'unknown'  => 'No usable successful-backup timestamp is retained.',
        'failed'   => 'The latest recorded backup attempt failed.',
        'disabled' => 'Automatic database backups are disabled.'
      }.freeze

      module_function

      def snapshot(now: Time.now.utc)
        mode = Muni::Store.backup_mode
        return ExternalBackup.snapshot(now: now) if mode == 'external'
        return disabled_snapshot if mode == 'disabled'

        keys = %w[maintenance:last_backup maintenance:last_backup_verified maintenance:last_backup_failure]
        rows = Muni::Store.db[:meta].where(key: keys)
                          .all.to_h { |row| [row[:key], row] }
        date, succeeded_at = success(rows['maintenance:last_backup'])
        verified_date, verified_at = success(rows['maintenance:last_backup_verified'])
        verified_at = succeeded_at unless verified_date == date
        failure = JSON.parse(rows.dig('maintenance:last_backup_failure', :value) || '{}')
        failed_at = failure.is_a?(Hash) ? time(failure['at']) : nil
        age = succeeded_at && [(now - succeeded_at).to_i, 0].max
        enabled = Muni::Store.maintenance_enabled?
        state = state(enabled, age, verified_at, failed_at)
        { status: state, detail: DETAILS.fetch(state), enabled: enabled, backend: 'local',
          last_backup_date: date, last_success_at: succeeded_at&.iso8601(6),
          last_verified_at: verified_at&.iso8601(6),
          age_seconds: age, max_age_seconds: MAX_AGE_SECONDS, last_failure_at: failed_at&.iso8601,
          failure_state: failure_state(verified_at, failed_at), time_basis: 'maintenance_metadata',
          retention: { daily: Muni::Store::BACKUP_DAILY_RETENTION, weekly: Muni::Store::BACKUP_WEEKLY_RETENTION } }
      rescue JSON::ParserError
        { status: 'unknown', detail: 'Backup maintenance metadata could not be read.' }
      end

      def success(row)
        return [nil, nil] unless row && row[:value].to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

        [row[:value], time(row[:updated_at])]
      end

      def disabled_snapshot
        { status: 'disabled', detail: DETAILS['disabled'], enabled: false, backend: 'disabled' }
      end

      def state(enabled, age, succeeded_at, failed_at)
        return 'failed' if failure_state(succeeded_at, failed_at) == 'failed'
        return 'disabled' unless enabled
        return 'unknown' unless age

        age > MAX_AGE_SECONDS ? 'overdue' : 'current'
      end

      def failure_state(succeeded_at, failed_at)
        return 'none_recorded' unless failed_at

        !succeeded_at || failed_at >= succeeded_at ? 'failed' : 'recovered'
      end

      def time(value)
        return value.utc if value.respond_to?(:utc)

        Time.parse("#{value} UTC").utc if value && !value.to_s.empty?
      rescue ArgumentError
        nil
      end
    end
  end
end
