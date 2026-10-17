module Muni
  module Water
    # Complete days use the same durable summaries as analytical signals. Only
    # boundary days or summaries awaiting materialization read raw observations.
    class DailySeries < Query
      def call(params, from:, to:)
        @params = params
        @from = from
        @to = to
        unless %w[source location parameter unit].all? { |key| params[key] && !params[key].empty? }
          raise Error, 'Choose a location, parameter and unit for measurement trends'
        end

        @dates = (Clock.day(@from)..Clock.day(@to - 1)).to_a
        summaries = summary_rows
        selectors = filtered(params.except('from', 'to')).where(kind: DailySummaries::KINDS)
                                                         .select(*DailySummaries::SELECTOR.map(&:to_sym)).distinct.all
        selectors |= summaries.map { |row| JSON.parse(row[:selector]).transform_keys(&:to_sym) }
        indexed = summaries.to_h { |row| [[row[:series_key], row[:date]], row] }
        selectors.map { |selector| series(selector, indexed) }
      end

      private

      def summary_rows
        columns = { 'location' => 'location_id', 'parameter' => 'parameter', 'unit' => 'unit',
                    'method' => 'method', 'segment' => 'segment', 'kind' => 'kind' }
        rows = Storage.db[:water_daily_summaries].where(source_slug:    @params['source'],
                                                        policy_version: DailySummaries::POLICY_VERSION,
                                                        date:           @dates.map(&:to_s))
        columns.each do |param, field|
          value = @params[param]
          rows = rows.where(Sequel.function(:json_extract, :selector, "$.#{field}") => value) if value && !value.empty?
        end
        rows.all
      end

      def series(selector, indexed)
        key = Water.hash(DailySummaries.selector(selector))
        summaries = @dates.to_h { |date| [date, usable_summary(indexed[[key, date.to_s]], date)] }
        raw = fallback_rows(selector, summaries)
        points = @dates.map do |date|
          summary = summaries[date]
          summary ? materialized_point(summary, date) : raw_point(selector, date, raw.fetch(date, []))
        end
        selector.slice(:kind, :unit, :method, :segment).merge(points: points)
      end

      def usable_summary(row, date)
        return unless row

        start, finish = Clock.bounds(date)
        return if start < @from || finish > [@to, @now].min
        return if JSON.parse(row[:payload])['partial']

        row
      end

      def fallback_rows(selector, summaries)
        dates = summaries.select { |_date, summary| summary.nil? }.keys
        return {} if dates.empty?

        queries = dates.chunk_while { |left, right| right == left + 1 }.map do |days|
          start = [Clock.eastern(days.first), @from].max
          finish = [Clock.eastern(days.last + 1), @to, @now].min
          Storage.evidence.where(selector).where { observed_at >= start }.where { observed_at < finish }
        end
        # Each disjoint window seeks the date range in the series index. A single
        # OR expression otherwise scans that series' entire retained history.
        rows = queries.reduce { |query, window| query.union(window, all: true, from_self: false) }.all
        RecordProjection.attach_raw(rows)
        rows.group_by { |row| Clock.day(row[:observed_at]) }
      end

      def materialized_point(row, date)
        JSON.parse(row[:payload], symbolize_names: true)
            .merge(date: date.to_s, observed_at: Clock.eastern(date), materialized: true,
                   policy_version: row[:policy_version], revision_cutoff: row[:revision_cutoff],
                   calculated_at: row[:calculated_at])
      end

      def raw_point(selector, date, rows)
        start, finish = Clock.bounds(date)
        effective_start = [start, @from].max
        effective_finish = [finish, @to, @now].min
        interval = Catalog.definitions.fetch(selector[:source_slug].delete_prefix(PREFIX)).fetch(:interval)
        DailySummaries.statistics(rows, start: effective_start, finish: effective_finish, interval: interval, now: @now)
                      .merge(date: date.to_s, observed_at: start, materialized: false,
                             partial: effective_start > start || effective_finish < finish,
                             policy_version: DailySummaries::POLICY_VERSION,
                             revision_cutoff: Storage.db[:water_revisions].max(:id) || 0,
                             input_revision_ids: rows.filter_map { |row| row[:revision_id] }.sort)
      end
    end
  end
end
