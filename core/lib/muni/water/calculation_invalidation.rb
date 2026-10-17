module Muni
  module Water
    # Prepared before the publication lock, applied inside the same transaction
    # as changed evidence. Historical calculation versions remain immutable.
    class CalculationInvalidation
      attr_reader :dirty

      def initialize(dirty, now: Time.now.utc)
        @dirty = dirty
        @today = Clock.day(now)
        entries = dirty.map { |entry| Water.canonical(entry) }.uniq
        @statements = summary_statements(entries) + signal_statements(entries)
      end

      def publish
        @statements.each { |statement| Storage.db.run(statement) }
      end

      private

      def summary_statements(entries)
        entries.group_by { |entry| Water.hash(entry['selector']) }.flat_map do |series, group|
          group.map { |entry| entry['date'] }.uniq.each_slice(500).map do |dates|
            Storage.db[:water_daily_summaries].where(series_key: series, date: dates).delete_sql
          end
        end
      end

      def signal_statements(entries)
        entries.flat_map { |entry| signal_keys(entry) }.uniq.each_slice(500).map do |keys|
          Storage.db[:water_signals].where(kind: 'sustained_sensor_shift', signal_key: keys).delete_sql
        end
      end

      def signal_keys(entry)
        selector = entry['selector']
        return [] unless selector['source_slug'] == "#{PREFIX}epa_buoy" && selector['kind'] == 'sensor'

        date = Date.parse(entry['date'])
        group = selector.slice('location_id', 'parameter', 'unit', 'method', 'segment')
        identity = Water.hash(group)
        (date..[date + 30, @today - 1].min).map { |last| "shift/#{identity}/#{last}" }
      end
    end
  end
end
