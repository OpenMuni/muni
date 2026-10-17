module Muni
  module Store
    # Copy bounded page batches without holding the application's writer lock.
    # Writes on this same SQLite handle update the backup instead of restarting it.
    class OnlineBackup
      def initialize(database)
        @database = database
      end

      def call(path)
        destination = SQLite3::Database.new(path)
        @database.synchronize do |source|
          backup = SQLite3::Backup.new(destination, 'main', source, 'main')
          copy(backup)
        ensure
          backup&.finish
        end
        # Standalone backups must not depend on transient WAL/SHM sidecars.
        destination.execute('PRAGMA journal_mode=DELETE')
      ensure
        destination&.close
      end

      private

      def copy(backup)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 900
        loop do
          result = backup.step(256)
          break if result == SQLite3::Constants::ErrorCode::DONE
          unless [SQLite3::Constants::ErrorCode::OK, SQLite3::Constants::ErrorCode::BUSY,
                  SQLite3::Constants::ErrorCode::LOCKED].include?(result)
            raise Sequel::DatabaseError, "SQLite backup failed (#{result})"
          end
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            raise Sequel::DatabaseError, 'SQLite backup exceeded its maintenance budget'
          end

          Thread.current[:muni_scheduler_yield]&.call
          sleep(0.005)
        end
      end
    end
  end
end
