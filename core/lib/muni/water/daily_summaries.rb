require 'muni/water/calculation_fence'

module Muni
  module Water
    class DailySummaries
      POLICY_VERSION = 'water-daily-v2'.freeze
      SELECTOR = %w[source_slug kind location_id parameter unit method segment].freeze
      KINDS = %w[sensor derived_sensor gauge prediction].freeze

      def initialize(now: Time.now.utc)
        @now = now
      end

      def self.selector(record)
        Water.canonical(record).slice(*SELECTOR)
      end

      def self.dirty(changes)
        dirty = {}
        changes.each do |change|
          [change[:before], change[:after]].compact.each do |record|
            row = record.transform_keys(&:to_s)
            next unless KINDS.include?(row['kind']) && row['observed_at']

            entry = { selector: row.slice(*SELECTOR), date: Clock.day(Water.time(row['observed_at'])).to_s }
            dirty[entry] = true
          end
        end
        dirty.keys
      end

      def refresh(dirty)
        return if dirty.empty?

        rows = prepare(dirty)
        versions = rows.map { |row| row.merge(id: Water.hash(row.except(:calculated_at))) }
        Muni::Store.with_writer { Storage.db.transaction { publish(rows, versions) } }
      end

      def prepare(dirty)
        Storage.db.transaction do
          cutoff = Storage.db[:water_revisions].max(:id) || 0
          dirty.uniq.map { |entry| summarize(entry, revision_cutoff: cutoff) }
        end
      end

      def publish(rows, versions)
        CalculationFence.verify!(rows.first[:revision_cutoff], rows.map { |row| row[:source_slug] }.uniq)
        versions.each_slice(500) do |batch|
          Storage.db[:water_daily_summary_versions].insert_conflict.multi_insert(batch)
        end
        rows.each_slice(500) do |batch|
          updates = %i[source_slug selector payload policy_version revision_cutoff calculated_at]
                    .to_h { |key| [key, Sequel[:excluded][key]] }
          next if batch.empty?

          fresh = Sequel[:water_daily_summaries][:revision_cutoff] <= Sequel[:excluded][:revision_cutoff]
          Storage.db[:water_daily_summaries].insert_conflict(target: %i[series_key date], update: updates,
                                                             update_where: fresh)
                 .multi_insert(batch)
        end
      end

      def summarize(entry, revision_cutoff: Storage.db[:water_revisions].max(:id) || 0)
        selector = Water.canonical(entry[:selector] || entry['selector'])
        date = (entry[:date] || entry['date']).to_s
        start, finish = Clock.bounds(Date.parse(date))
        rows = Storage.evidence.where(selector.transform_keys(&:to_sym))
                      .where { observed_at >= start }.where { observed_at < finish }
                                                     .order(:observed_at, :external_id).all
        definition = Catalog.definitions.fetch(selector['source_slug'].delete_prefix(PREFIX))
        stats = self.class.statistics(rows, start: start, finish: finish,
                                     interval: definition.fetch(:interval), now: @now)
        stats[:input_revision_ids] = input_revision_ids(rows, revision_cutoff)
        { series_key: Water.hash(selector), date: date, source_slug: selector['source_slug'],
          selector: Water.json(selector), payload: Water.json(stats), policy_version: POLICY_VERSION,
          revision_cutoff: revision_cutoff, calculated_at: @now }
      end

      def self.statistics(rows, start:, finish:, interval:, now: Time.now.utc)
        effective_finish = [finish, now].min
        expected = [((effective_finish.to_f / interval).ceil - (start.to_f / interval).ceil), 0].max
        eligible = eligible_rows(rows, start, effective_finish)
        values = eligible.filter_map { |row| row[:value] }.sort
        coverage = expected.positive? ? [values.length.to_f / expected, 1.0].min : 0
        median = values.empty? ? nil : (values[(values.length - 1) / 2] + values[values.length / 2]) / 2.0
        reason = eligibility_reason(values, expected, coverage)
        { value: reason ? nil : median, median: median, min: values.first, max: values.last,
          received: values.length, published: rows.length, expected: expected, coverage: coverage,
          partial: finish > now, eligibility_reason: reason,
          input_fingerprint: input_fingerprint(eligible),
          input_normalization_versions: normalization_versions(rows),
          fetched_at: rows.filter_map { |row| row[:fetched_at] }.max }
      end

      def close_days
        Calculations.with_lock { close_next_day }
      end

      def self.eligible_rows(rows, start, finish)
        eligible = rows.select do |row|
          time = Water.time(row[:observed_at])
          time && time >= start && time < finish && Eligibility.calculable?(row)
        end
        eligible.sort_by { |row| [Water.time(row[:observed_at]), row[:external_id].to_s] }
                .uniq { |row| row[:observed_at] }
      end

      def self.eligibility_reason(values, expected, coverage)
        return 'No eligible observations in this period.' if expected.zero? || values.empty?
        return 'Fewer than 80% of expected observations are available.' if coverage < 0.8

        nil
      end

      def self.input_fingerprint(rows)
        Water.hash(rows.map do |row|
          row.slice(:external_id, :observed_at, :value, :status, :normalization_version, :payload)
        end)
      end

      def self.normalization_versions(rows)
        rows.map { |row| row[:normalization_version] || 'unknown' }.uniq.sort
      end

      private

      def input_revision_ids(rows, revision_cutoff)
        Storage.db[:water_revisions].where(evidence_id: rows.map { |row| row[:external_id] })
               .where { id <= revision_cutoff }.group(:evidence_id).select_map { max(id) }.sort
      end

      def close_next_day
        today = Clock.day(@now).to_s
        previous = Muni::Store.meta('water:last_closed_day')
        return if previous && previous >= today

        date = previous ? Date.parse(previous) : Date.parse(today) - 1
        selectors = Storage.db[:water_daily_summaries].select(:selector).distinct.select_map(:selector)
                           .map { |value| JSON.parse(value) }
        selectors = Storage.evidence.where(kind: KINDS).select(*SELECTOR.map(&:to_sym)).distinct.all if selectors.empty?
        # One complete local day per maintenance tick also bounds restart catch-up.
        dirty = selectors.map { |selector| { selector: selector, date: date.to_s } }
        refresh(dirty)
        SensorShifts.new(now: @now, publisher: Signals.new(now: @now)).calculate(dirty: dirty)
        Muni::Store.set_meta('water:last_closed_day', (date + 1).to_s)
      end
    end
  end
end
