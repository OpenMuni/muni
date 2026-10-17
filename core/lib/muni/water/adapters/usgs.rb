module Muni
  module Water
    module Adapters
      class Usgs < Base
        def collect
          @now = client.snapshot_time
          prepare_history
          routine = !checkpoint['history_cursor'] || !checkpoint['routine_due_at'] ||
                    Water.time(checkpoint['routine_due_at']) <= @now
          start, finish = collection_window(routine)
          records = %w[00060 00065].flat_map { |parameter| series(parameter, start, finish) }
          advance_window(routine, start)
          @metadata = { full_reconciliation: !routine, contextual_only: true,
                        backfill_pending: checkpoint.key?('history_cursor'),
                        collection_window: { start: start.iso8601, end: finish.iso8601 },
                        history_complete_through: checkpoint['reconciled_month'] }
          records
        end

        private

        def prepare_history
          month = @now.strftime('%Y-%m')
          return if checkpoint['reconciled_month'] == month || checkpoint['history_cursor']

          checkpoint['history_month'] = month
          checkpoint['history_start'] = Time.utc(@now.year).iso8601
          checkpoint['history_cursor'] = [@now - (7 * 86_400), Time.utc(@now.year)].max.iso8601
          checkpoint.delete('routine_due_at')
        end

        def collection_window(routine)
          return [@now - (7 * 86_400), @now] if routine || !checkpoint['history_cursor']

          finish = Water.time(checkpoint['history_cursor'])
          [[finish - (7 * 86_400), Water.time(checkpoint['history_start'])].max, finish]
        end

        def advance_window(routine, start)
          if routine
            checkpoint['routine_due_at'] = Schedule.new(slug, definition).next_after(@now).iso8601
          elsif checkpoint['history_cursor']
            checkpoint['history_cursor'] = start.iso8601
          end
          return unless checkpoint['history_cursor'] &&
                        Water.time(checkpoint['history_cursor']) <= Water.time(checkpoint['history_start'])

          checkpoint['reconciled_month'] = checkpoint.delete('history_month')
          checkpoint.delete('history_cursor')
          checkpoint.delete('history_start')
        end

        def series(parameter, start, finish)
          params = { monitoring_location_id: 'USGS-01104500', parameter_code: parameter,
                     datetime: "#{start.utc.iso8601}/#{finish.utc.iso8601}", limit: 10_000, f: 'json' }
          path = "#{url}/continuous/items"
          records = []
          visited = []
          loop do
            raise Error, 'Invalid USGS pagination' if visited.include?(path) || visited.length > 100

            visited << path
            data = json(client.get(path, params, conditional: false))
            records.concat(data.fetch('features').map { |feature| observation(feature) })
            Thread.current[:muni_scheduler_yield]&.call
            path = data.fetch('links', []).find { |link| link['rel'] == 'next' }&.fetch('href')
            break unless path
            raise Error, 'Unexpected USGS pagination origin' unless path.start_with?("#{url}/continuous/items?")

            params = {}
          end
          records
        end

        def observation(feature)
          row = feature.fetch('properties')
          raise Error, 'Unexpected USGS station' unless row['monitoring_location_id'] == 'USGS-01104500'

          record(id: [row.fetch('time_series_id'), row.fetch('time')].join('/'), kind: 'gauge',
                 location_id: 'USGS-01104500', observed_at: Time.iso8601(row.fetch('time')),
                 published_at: row['last_modified'] && Time.iso8601(row['last_modified']), original_timezone: 'UTC',
                 parameter: row['parameter_code'] == '00060' ? 'flow' : 'level', value: number(row.fetch('value')),
                 unit: row.fetch('unit_of_measure'), status: row.fetch('approval_status'),
                 method: row['method_category'], segment: row.fetch('time_series_id'), raw: row,
                 payload: { qualifier: row['qualifier'], original_value: row['value'], contextual_only: true })
        end
      end
    end
  end
end
