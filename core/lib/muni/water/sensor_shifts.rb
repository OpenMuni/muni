module Muni
  module Water
    class SensorShifts
      def initialize(now:, publisher:)
        @now = now
        @publisher = publisher
      end

      def calculate(dirty: nil)
        if dirty
          selected = direct_sensor_days(dirty)
          selected.group_by { |entry| entry['selector'] }.each do |selector, entries|
            dates = entries.map { |entry| Date.parse(entry['date']) }
            calculate_cached(selector, dates)
          end
        else
          dataset = Storage.evidence.where(source_slug: "#{PREFIX}epa_buoy", kind: 'sensor')
          dataset.select(*DailySummaries::SELECTOR.map(&:to_sym)).distinct.each do |selector|
            rows = dataset.where(selector).exclude(observed_at: nil).all
            dirty_days = rows.map { |row| Clock.day(row[:observed_at]) }.uniq
            DailySummaries.new(now: @now).refresh(dirty_days.map { |date| { selector: selector, date: date.to_s } })
            calculate_cached(Water.canonical(selector), dirty_days)
          end
        end
      end

      def calculate_cached(selector, dates)
        return if dates.empty?

        today = Clock.day(@now)
        ends = dates.flat_map { |date| (date..[date + 30, today - 1].min).to_a }
        ends.uniq!
        return if ends.empty?

        cutoff, cached = cached_days(selector, ends)
        summary = cached.to_h do |row|
          data = JSON.parse(row[:payload], symbolize_names: true)
          data[:revision_cutoff] = row[:revision_cutoff]
          [Date.parse(row[:date]), data]
        end
        # Retain the established signal identity while versioning its policy.
        group = selector.slice('location_id', 'parameter', 'unit', 'method', 'segment').transform_keys(&:to_sym)
        ends.sort.each do |date|
          evaluate(summary, group, date, latest: date == today - 1, revision_cutoff: cutoff)
          Thread.current[:muni_scheduler_yield]&.call
        end
      end

      def evaluate(days, group, date, latest:, revision_cutoff: Storage.db[:water_revisions].max(:id) || 0)
        recent = qualifying_days(days, (date - 2)..date)
        baseline = qualifying_days(days, (date - 30)..(date - 3))
        center = median(baseline.map { |day| day[:median] })
        sigma = center && (1.4826 * median(baseline.map { |day| (day[:median] - center).abs }))
        classification = classify(recent, baseline, center, sigma)
        key = "shift/#{Water.hash(group)}/#{date}"
        return unless latest || classification[:status] == 'detected' ||
                      Storage.db[:water_signal_versions].where(signal_key: key).any?

        payload = shift_payload(group, date, days, center, sigma, baseline.length, recent.length)
        payload[:evidence][:revision_cutoff] = revision_cutoff
        @publisher.publish(key, 'sustained_sensor_shift', classification.delete(:status), payload.merge(classification))
      end

      private

      def cached_days(selector, ends)
        Storage.db.transaction do
          [Storage.db[:water_revisions].max(:id) || 0,
           Storage.db[:water_daily_summaries].where(series_key: Water.hash(selector))
                  .where(date: (ends.min - 30).to_s..ends.max.to_s).all]
        end
      end

      def direct_sensor_days(dirty)
        dirty.map { |entry| Water.canonical(entry) }.select do |entry|
          entry.dig('selector', 'source_slug') == "#{PREFIX}epa_buoy" && entry.dig('selector', 'kind') == 'sensor'
        end
      end

      def qualifying_days(days, range)
        range.filter_map { |day| days[day] }.select { |day| day[:coverage] >= 0.8 && !day[:partial] && day[:median] }
      end

      def classify(recent, baseline, center, sigma)
        unless recent.length == 3 && baseline.length >= 21 && sigma&.positive?
          return { status: 'suppressed', explanation: 'Insufficient evidence or zero baseline dispersion.' }
        end

        deltas = recent.map { |day| (day[:median] - center) / sigma }
        direction = 'higher' if deltas.all? { |value| value > 3 }
        direction = 'lower' if deltas.all? { |value| value < -3 }
        unless direction
          return { status:      'not_detected',
                   explanation: 'No sustained measurement shift in this window.' }
        end

        { status: 'detected', direction: direction,
          explanation: 'Sustained measurement shift across three complete local days.' }
      end

      def shift_payload(group, date, days, center, sigma, baseline_count, recent_count)
        selected = days.select { |day, _| day.between?(date - 30, date) }
        { source_slug: "#{PREFIX}epa_buoy", selector: group,
          window: { baseline_start: (date - 30).to_s, baseline_end: (date - 3).to_s,
                    comparison_start: (date - 2).to_s, comparison_end: date.to_s, timezone: 'America/New_York' },
          method: 'Three day medians each > 3 robust SD in the same direction; SD = 1.4826 × MAD.',
          baseline_median: center, robust_standard_deviation: sigma,
          coverage: { qualifying_baseline_days: baseline_count, required_baseline_days: 21,
                      qualifying_recent_days: recent_count, minimum_daily_fraction: 0.8 },
          evidence: { daily_statistics:       selected.transform_keys(&:to_s),
                      revision_ids:           selected.values.flat_map do |row|
                        row.fetch(:input_revision_ids, [])
                      end.uniq.sort,
                      daily_revision_cutoffs: selected.transform_keys(&:to_s).transform_values do |row|
                        row[:revision_cutoff]
                      end },
          limitations: 'Measurement shift only. Seasonal and environmental changes can cause shifts. ' \
                       'This is not a health threshold or proof of pollution or sensor failure.' }
      end

      def median(values)
        return nil if values.empty?

        sorted = values.sort
        middle = sorted.length / 2
        sorted.length.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
      end
    end
  end
end
