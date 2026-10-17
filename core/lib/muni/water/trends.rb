module Muni
  module Water
    # Display aggregates only; permanent records and analytical signals stay unchanged.
    class Trends < Query
      def call(params)
        Storage.db.transaction { snapshot(params) }
      end

      def snapshot(params)
        prepare(params)
        discrete = params['kind'] == 'laboratory' || @source.end_with?('/crwa_predictions')
        return observation_series if params['presentation'] == 'observations' && discrete
        return daily_series unless @counts

        count_series
      end

      private

      def count_series
        rows = @checks ? check_rows : eligible_rows(@params.merge('from' => @from.iso8601, 'to' => @to.iso8601)).all
        RecordProjection.attach_raw(rows, cutoff: @revision_cutoff) unless @checks
        @first = observation_time(first_observation)
        @last = observation_time(eligible_rows(@params.except('from', 'to')).max(observation_order)) unless @checks
        envelope(source_slug: @source, from: @from, to: @to, timezone: 'America/New_York',
                 statistic: 'count', aggregation: @aggregation, metric: metric_label,
                 record_count: rows.length, series: [trend_series(rows)])
      end

      def observation_order
        Sequel.lit('COALESCE(observed_at, observed_date)')
      end

      def observation_time(value)
        value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? Clock.eastern(value) : Water.time(value)
      end

      def observation_day(row)
        row[:observed_date] ? Date.parse(row[:observed_date]) : Clock.day(row[:observed_at])
      end

      def daily_series
        series = DailySeries.new(now: @now).call(@params, from: @from, to: @to)
        envelope(source_slug: @source, from: @from, to: @to, timezone: 'America/New_York',
                 statistic: 'median', aggregation: 'day', metric: metric_label, interpolation: 'none',
                 record_count: series.sum { |group| group[:points].sum { |point| point[:published].to_i } },
                 series: series)
      end

      def prepare(params)
        @params = params
        @revision_cutoff = Storage.db[:water_revisions].max(:id) || 0
        @source = params.fetch('source', '')
        @definition = Catalog.definitions[@source.delete_prefix(PREFIX)]
        raise Error, 'Choose a water source' unless @source.start_with?(PREFIX) && @definition

        @from = params['from'] ? filter_time(params['from']) : @now - (30 * 86_400)
        @to = params['to'] ? filter_time(params['to']) : @now
        raise Error, 'Choose a period of 1–365 days' unless @to > @from && @to - @from <= 366 * 86_400

        @checks = @source.end_with?('/crwa_boathouses')
        @counts = @checks || !@definition[:interval]
        @count_unit = @checks ? 'checks' : 'records'
        @aggregation = params.fetch('aggregation', 'day')
        validate_aggregation!
      end

      def validate_aggregation!
        return if @aggregation == 'day' || (@aggregation == 'month' && @counts && !@checks)

        raise Error, 'Choose daily measurements or daily/monthly publication counts'
      end

      def metric_label
        return 'Successful checks' if @checks
        return 'Published records' if @counts

        @params['parameter']
      end

      def eligible_rows(params)
        dataset = filtered(params)
                  .where(Sequel.lit("COALESCE(LOWER(status), '') NOT IN ('retracted', 'needs_review', 'rejected')"))
        if @source.end_with?('_cso')
          dataset = dataset.where(Sequel.lit("COALESCE(json_extract(payload, '$.countable'), 1) = 1"))
        end
        dataset
      end

      def check_rows
        from = @from
        to = @to
        Storage.db[:water_runs].where(source_slug: @source, status: 'complete')
               .where { started_at >= from }.where { started_at < to }
                                            .select(:started_at, :ended_at).all.map do |row|
          { observed_at: row[:started_at], fetched_at: row[:ended_at] }
        end
      end

      def first_observation
        return Storage.db[:water_runs].where(source_slug: @source).min(:started_at) if @checks

        eligible_rows(@params.except('from', 'to')).min(observation_order)
      end

      def trend_series(rows)
        return monthly_series(rows) if @aggregation == 'month'

        daily = rows.group_by { |row| observation_day(row) }
        points = (Clock.day(@from)..Clock.day(@to - 1)).map do |date|
          point(date, daily.fetch(date, []))
        end
        { kind: nil, unit: @count_unit, method: nil, segment: nil, points: points }
      end

      def monthly_series(rows)
        monthly = rows.group_by { |row| observation_day(row).strftime('%Y-%m') }
        date = Clock.day(@from).then { |day| Date.new(day.year, day.month, 1) }
        points = []
        while date <= Clock.day(@to - 1)
          start = Clock.eastern(date)
          finish = Clock.eastern(date >> 1)
          values = monthly.fetch(date.strftime('%Y-%m'), [])
          points << { date: date.to_s, observed_at: start, received: values.length,
                      value: count_value(start, finish, values),
                      partial: start < @from || finish > [@to, @now].min,
                      fetched_at: values.filter_map { |row| row[:fetched_at] }.max }.merge(lineage(values))
          date >>= 1
        end
        { kind: nil, unit: @count_unit, method: nil, segment: nil, points: points }
      end

      def count_value(start, finish, rows)
        return nil unless @first && finish > @first && start < [@to, @now].min
        return nil if !@checks && (!@last || start > @last)

        rows.length
      end

      def point(date, rows)
        start, finish = Clock.bounds(date)
        effective_start = [start, @from].max
        effective_end = [finish, @to, @now].min
        common = { observed_at: start, date: date.to_s, received: rows.length,
                   fetched_at: rows.filter_map { |row| row[:fetched_at] }.max,
                   partial: effective_start > start || effective_end < finish }
        # No checks before monitoring began; zero checks are meaningful afterwards.
        common.merge(lineage(rows)).merge(value: count_value(start, finish, rows))
      end

      def lineage(rows)
        { input_revision_ids: rows.filter_map { |row| row[:revision_id] }.sort,
          input_normalization_versions: rows.map { |row| row[:normalization_version] || 'unknown' }.uniq.sort,
          revision_cutoff: @revision_cutoff, policy_version: DailySummaries::POLICY_VERSION }
      end

      def observation_points(values)
        values.sort_by { |row| [row['observed_date'].to_s, row['observed_at'].to_s, row['external_id']] }
              .map do |row|
          row.slice('external_id', 'observed_at', 'observed_date', 'time_precision', 'value', 'eligibility',
                    'publication_count', 'payload', 'revision_id', 'revision_cutoff', 'normalization_version',
                    'policy_version', 'source_url').merge('date' => row['observed_date'], 'received' => 1)
        end
      end

      def observation_series
        unless %w[location parameter unit].all? { |key| @params[key] && !@params[key].empty? }
          raise Error, 'Choose a location, parameter and unit for observations'
        end

        rows = filtered(@params.merge('from' => @from.iso8601, 'to' => @to.iso8601)).all
        records = Eligibility.select(rows.map { |row| Storage.decode(row) })
        records = records.select { |row| row.dig('eligibility', 'primary') }
        RecordProjection.attach(records)
        groups = records.group_by { |row| [row['kind'], row['unit'], row['method'], row['segment']] }
        series = groups.map do |(kind, unit, method, segment), values|
          points = observation_points(values)
          { kind: kind, unit: unit, method: method, segment: segment, points: points }
        end
        envelope(source_slug: @source, from: @from, to: @to, timezone: 'America/New_York',
                 statistic: 'observation', aggregation: 'none', metric: @params['parameter'],
                 interpolation: 'none', record_count: records.length, series: series)
      end
    end
  end
end
