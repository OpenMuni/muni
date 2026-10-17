module Muni
  module Water
    class AggregatedSeries < Query
      def call(params)
        Storage.db.transaction { snapshot(params) }
      end

      def snapshot(params)
        aggregation = params.fetch('aggregation', 'none')
        raise Error, 'aggregation must be none, hour, or day' unless %w[none hour day].include?(aggregation)
        return records(params) if aggregation == 'none'
        unless params['location'] && params['parameter']
          raise Error,
                'Select a location and parameter for chart aggregation'
        end

        dataset = filtered(params).where(kind: %w[sensor derived_sensor gauge])
        raise Error, 'Chart window exceeds 365 days' if dataset.count > 60_000

        rows = dataset.order(:observed_at).all
        RecordProjection.attach_raw(rows)
        groups = rows.group_by do |row|
          bucket = bucket_time(row[:observed_at], aggregation)
          [row[:source_slug], row[:kind], row[:unit], row[:method], row[:segment], bucket]
        end
        values = groups.map { |key, rows| aggregate(key, rows, aggregation, params) }
        envelope(records: values, aggregation: aggregation, statistic: 'median', timezone: 'America/New_York',
                 interpolation: 'none', total: values.length)
      end

      private

      def bucket_time(time, aggregation)
        aggregation == 'day' ? Clock.day(time).to_s : time.utc.strftime('%Y-%m-%dT%H:00:00Z')
      end

      def statistics(rows, start, finish, interval, params)
        from = params['from'] ? [start, filter_time(params['from'])].max : start
        to = params['to'] ? [finish, filter_time(params['to']), @now].min : [finish, @now].min
        stats = DailySummaries.statistics(rows, start: from, finish: to, interval: interval, now: @now)
        stats[:partial] = from > start || to < finish
        stats[:input_revision_ids] = rows.filter_map { |row| row[:revision_id] }.sort
        stats[:revision_cutoff] = Storage.db[:water_revisions].max(:id) || 0
        stats[:policy_version] = DailySummaries::POLICY_VERSION
        stats
      end

      def aggregate(key, rows, aggregation, params)
        source, kind, unit, method, segment, bucket = key
        start, finish = if aggregation == 'day'
                          Clock.bounds(Date.parse(bucket))
                        else
                          [Time.iso8601(bucket), Time.iso8601(bucket) + 3600]
                        end
        interval = Catalog.definitions.fetch(source.delete_prefix(PREFIX)).fetch(:interval)
        stats = statistics(rows, start, finish, interval, params)
        { source_slug: source, kind: kind, location_id: rows.first[:location_id], parameter: rows.first[:parameter],
          unit: unit, method: method, segment: segment, observed_at: bucket, date: Clock.day(start).to_s,
          aggregation: aggregation, statistic: 'median', source_url: rows.first[:source_url],
          status: rows.map { |row| row[:status] }.uniq }.merge(stats)
      end
    end
  end
end
