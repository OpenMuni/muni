module Muni
  module Status
    # Only a small, private evidence file is read; no S3 requests or database writes.
    module ExternalBackup
      module_function

      def snapshot(now: Time.now.utc)
        evidence = read_evidence
        captured, verified, failed = timeline(evidence, now)
        retention = evidence.fetch('retention')
        valid = retention.is_a?(Hash) && %w[local_snapshots s3_days].all? do |key|
          retention[key].is_a?(Integer) && retention[key].positive?
        end
        raise ArgumentError unless valid

        age = captured && [(now - captured).to_i, 0].max
        state = Backup.state(true, age, verified, failed)
        { status: state, detail: Backup::DETAILS.fetch(state), enabled: true, backend: 'external',
          last_backup_date: captured&.strftime('%Y-%m-%d'), last_success_at: captured&.iso8601(6),
          last_verified_at: verified&.iso8601(6), last_failure_at: failed&.iso8601(6),
          age_seconds: age, max_age_seconds: Backup::MAX_AGE_SECONDS,
          failure_state: Backup.failure_state(verified, failed), time_basis: 'external_capture',
          verification: 's3_checksum',
          retention: { daily: 0, weekly: 0, local_snapshots: retention['local_snapshots'],
                       s3_days: retention['s3_days'] } }
      rescue SystemCallError, IOError, JSON::ParserError, ArgumentError, KeyError, TypeError
        { status: 'unknown', detail: 'External backup evidence is missing or invalid.',
          enabled: true, backend: 'external' }
      end

      def read_evidence
        default = File.join(File.dirname(Muni::Config.db_path), 'backups', 'offsite', 'status.json')
        path = ENV.fetch('MUNI_BACKUP_STATUS_PATH', default)
        raise ArgumentError if File.symlink?(path)

        evidence = File.open(path) do |file|
          raise ArgumentError unless file.stat.file? && file.stat.size <= 16_384

          JSON.parse(file.read(16_385))
        end
        raise ArgumentError unless evidence.is_a?(Hash) && evidence['schema_version'] == 1

        evidence
      end

      def timeline(evidence, now)
        captured = parse_time(evidence['captured_at'])
        verified = parse_time(evidence['verified_at'])
        failed = parse_time(evidence['last_failure_at'])
        raise ArgumentError if captured.nil? != verified.nil?
        raise ArgumentError if captured && (captured.to_i <= 0 || verified < captured || verified > now + 60)
        raise ArgumentError if failed && (failed.to_i <= 0 || failed > now + 60)

        [captured, verified, failed]
      end

      def parse_time(value)
        return nil if value.nil?
        raise ArgumentError unless value.is_a?(String) && value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)

        Time.iso8601(value).utc
      end
    end
  end
end
