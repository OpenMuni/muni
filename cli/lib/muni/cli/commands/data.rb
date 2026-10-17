require 'muni/command'

module Muni
  module CLI
    module Commands
      module Data
        class Migrate < Muni::Command
          description 'Ensure all schema tables exist (idempotent).'

          def go
            Muni::Store.ensure_tables!
            emit(ok: true, tables: Muni::Store.db.tables.map(&:to_s).sort)
          end
        end

        class Status < Muni::Command
          description 'Show table counts and last-seen cursors.'

          def go
            emit(Muni::Data.status)
          end
        end

        class Orphans < Muni::Command
          description 'Report tables not owned by current records or operational stores.'

          def go
            emit(orphan_tables: Muni::Store.orphan_tables)
          end
        end

        class Optimize < Muni::Command
          description 'Optimize database: checkpoint WAL, analyze indexes, vacuum if needed.'

          def go
            before_size = begin
              File.size(Muni::Config.db_path)
            rescue StandardError
              0
            end
            wal_path = "#{Muni::Config.db_path}-wal"
            wal_before = begin
              File.size(wal_path)
            rescue StandardError
              0
            end

            Muni::Store.optimize!

            after_size = begin
              File.size(Muni::Config.db_path)
            rescue StandardError
              0
            end
            wal_after = begin
              File.size(wal_path)
            rescue StandardError
              0
            end

            emit(
              ok:               true,
              db_size_before:   before_size,
              db_size_after:    after_size,
              wal_size_before:  wal_before,
              wal_size_after:   wal_after,
              wal_reclaimed_kb: ((wal_before - wal_after) / 1024.0).round(1)
            )
          end
        end

        class Prune < Muni::Command
          description 'Remove old records beyond retention period. Use --dry-run to preview.'
          option :dry_run, type: :boolean, default: false

          # Retention policies by record type (days)
          RETENTION = {
            service_requests:         365,
            police_log_entrys:        180,
            dispatch_calls:           180,
            building_permits:         365,
            new_construction_permits: 365,
            crime_reports:            730,
            crashs:                   730, # 2 years for crash data
            cpd_crashs:               730,
            parking_tickets:          730,
            traffic_volume_dailys:    1095,
            bicycle_counts:           1095,
            pedestrian_count_dailys:  1095,
            beats_log:                90
          }.freeze

          def go
            results = {}
            dry = opts[:dry_run]

            RETENTION.each do |table, days|
              next unless Muni::Store.db.table_exists?(table)

              time_col = time_column_for(table)
              next unless time_col

              cutoff = Time.now.utc - (days * 24 * 60 * 60)
              ds = Muni::Store.db[table].where(Sequel.lit("#{time_col} < ?", cutoff))
              count = ds.count

              Muni::Store.with_writer { ds.delete } if count.positive? && !dry

              results[table.to_s] = { would_delete: count, cutoff: cutoff.iso8601, days: days }
            end

            emit(dry_run: dry, pruned: results)
          end

          TIME_COLUMNS = {
            service_requests:         :opened_at,
            police_log_entrys:        :reported_at,
            dispatch_calls:           :received_at,
            building_permits:         :issued_at,
            new_construction_permits: :issued_at,
            crime_reports:            :reported_at,
            crashs:                   :occurred_at,
            cpd_crashs:               :occurred_at,
            parking_tickets:          :issued_at,
            traffic_volume_dailys:    :observed_at,
            bicycle_counts:           :observed_at,
            pedestrian_count_dailys:  :observed_at,
            beats_log:                :started_at
          }.freeze
          private_constant :TIME_COLUMNS

          def time_column_for(table)
            TIME_COLUMNS[table]
          end
        end
      end
    end
  end
end

Muni::CLI::Router.register('data', default:  :status,
                                   migrate:  Muni::CLI::Commands::Data::Migrate,
                                   status:   Muni::CLI::Commands::Data::Status,
                                   orphans:  Muni::CLI::Commands::Data::Orphans,
                                   optimize: Muni::CLI::Commands::Data::Optimize,
                                   prune:    Muni::CLI::Commands::Data::Prune)
