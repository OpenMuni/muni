require 'muni/analytics/support'

module Muni
  module Analytics
    class SafetyAnomalies
      CURRENT_WINDOW_DAYS = 7
      HISTORY_WEEKS = 26
      MIN_CURRENT_COUNT = 3
      MIN_BASELINE_WINDOWS = 4
      MIN_RATIO = 2.0
      MIN_Z_SCORE = 3.0

      SOURCES = [
        [-> { Muni::Records::CrimeReport }, :reported_at, :crime_category, 'crime'],
        [-> { Muni::Records::DispatchCall }, :received_at, :incident_type, 'dispatch'],
        [-> { Muni::Records::CpdCrash }, :occurred_at, :location_description, 'recent_crash']
      ].freeze

      class << self
        def compute(hall:, now: Time.now.utc)
          rows = source_rows(hall)
          latest = rows.map { |row| row[:time] }.max
          return warming_payload(now) unless latest

          current_start = latest - (CURRENT_WINDOW_DAYS * Support::DAY_SECONDS)
          anomalies = detect(rows, latest, current_start)
          {
            'status'        => 'ready',
            'generated_at'  => Support.iso_time(now),
            'source_max_at' => Support.iso_time(latest),
            'window_days'   => CURRENT_WINDOW_DAYS,
            'anomalies'     => anomalies
          }
        end

        private

        def source_rows(hall)
          SOURCES.flat_map do |record_ref, time_field, type_field, kind|
            record_class = record_ref.call
            ds = Support.dataset(record_class, hall)
            next [] unless ds

            Support.each_row(ds.select(time_field, type_field)).filter_map do |row|
              time = Support.time_value(row[time_field])
              label = Support.normalized_label(row[type_field])
              next unless time

              { kind: kind, label: label, key: "#{kind}:#{label}", time: time }
            end
          end
        end

        def warming_payload(now)
          {
            'status'       => 'warming',
            'generated_at' => Support.iso_time(now),
            'anomalies'    => []
          }
        end

        def detect(rows, latest, current_start)
          anomalies = rows.group_by { |row| row[:key] }.filter_map do |key, grouped|
            current_count = grouped.count { |row| row[:time].between?(current_start, latest) }
            next if current_count < MIN_CURRENT_COUNT

            baseline = baseline_counts(grouped, current_start)
            next if baseline.length < MIN_BASELINE_WINDOWS

            baseline_median = Support.median(baseline).to_f
            next unless baseline_median.positive?

            ratio = current_count / baseline_median
            z_score = Support.robust_z_score(current_count, baseline)
            next if ratio < MIN_RATIO || z_score < MIN_Z_SCORE

            sample = grouped.first
            {
              'key'            => key,
              'kind'           => sample[:kind],
              'label'          => sample[:label],
              'current_count'  => current_count,
              'baseline_count' => baseline_median.round(1),
              'ratio'          => ratio.round(1),
              'z_score'        => z_score.round(2),
              'basis'          => 'rolling prior weeks',
              'severity'       => ratio >= 3.0 || z_score >= 6.0 ? 'high' : 'medium'
            }
          end

          anomalies.sort_by { |row| [-row['z_score'], -row['current_count'], row['key']] }
        end

        def baseline_counts(grouped, current_start)
          history_start = current_start - (HISTORY_WEEKS * CURRENT_WINDOW_DAYS * Support::DAY_SECONDS)
          matching = grouped.select { |row| row[:time] >= history_start && row[:time] < current_start }
          window_counts(matching, history_start, current_start).reject(&:zero?)
        end

        def window_counts(rows, start_time, end_time)
          window_seconds = CURRENT_WINDOW_DAYS * Support::DAY_SECONDS
          count = ((end_time - start_time) / window_seconds).floor
          return [] unless count.positive?

          counts = Array.new(count, 0)
          rows.each do |row|
            index = ((row[:time] - start_time) / window_seconds).floor
            counts[index] += 1 if index >= 0 && index < count
          end
          counts
        end
      end
    end
  end
end
