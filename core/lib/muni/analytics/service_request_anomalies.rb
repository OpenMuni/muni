require 'muni/analytics/support'

module Muni
  module Analytics
    class ServiceRequestAnomalies
      CURRENT_WINDOW_DAYS = 7
      HISTORY_WEEKS = 26
      MIN_CURRENT_COUNT = 5
      MIN_BASELINE_WINDOWS = 4
      MIN_RATIO = 2.0
      MIN_Z_SCORE = 3.0

      class << self
        def compute(hall:, now: Time.now.utc)
          ds = Support.dataset(Muni::Records::ServiceRequest, hall)
          return warming_payload(now) unless ds

          rows = Support.each_row(ds.select(:case_type, :opened_at)).filter_map do |row|
            opened_at = Support.time_value(row[:opened_at])
            next unless opened_at

            { case_type: Support.normalized_label(row[:case_type]), opened_at: opened_at }
          end
          latest = rows.map { |row| row[:opened_at] }.max
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

        def warming_payload(now)
          {
            'status'       => 'warming',
            'generated_at' => Support.iso_time(now),
            'anomalies'    => []
          }
        end

        def detect(rows, latest, current_start)
          anomalies = rows.group_by { |row| row[:case_type] }.filter_map do |case_type, grouped|
            current_count = grouped.count do |row|
              row[:opened_at].between?(current_start, latest)
            end
            next if current_count < MIN_CURRENT_COUNT

            baseline, basis = baseline_counts(grouped, latest, current_start)
            next if baseline.length < MIN_BASELINE_WINDOWS

            baseline_median = Support.median(baseline).to_f
            next unless baseline_median.positive?

            ratio = current_count / baseline_median
            z_score = Support.robust_z_score(current_count, baseline)
            next if ratio < MIN_RATIO || z_score < MIN_Z_SCORE

            anomaly_row(case_type, current_count, baseline_median, ratio, z_score, basis)
          end
          anomalies.sort_by { |row| [-row['z_score'], -row['current_count'], row['case_type']] }
        end

        def baseline_counts(grouped, latest, current_start)
          seasonal = seasonal_counts(grouped, latest, current_start)
          return [seasonal, 'seasonal same-month weeks'] if seasonal.length >= MIN_BASELINE_WINDOWS

          [rolling_counts(grouped, current_start), 'rolling prior weeks']
        end

        def seasonal_counts(grouped, latest, current_start)
          month = latest.month
          matching = grouped.select { |row| row[:opened_at] < current_start && row[:opened_at].month == month }
          return [] if matching.empty?

          matching.group_by { |row| row[:opened_at].strftime('%G-%V') }
                  .values
                  .map(&:length)
        end

        def rolling_counts(grouped, current_start)
          history_start = current_start - (HISTORY_WEEKS * CURRENT_WINDOW_DAYS * Support::DAY_SECONDS)
          matching = grouped.select { |row| row[:opened_at] >= history_start && row[:opened_at] < current_start }
          window_counts(matching, history_start, current_start).reject(&:zero?)
        end

        def window_counts(rows, start_time, end_time)
          window_seconds = CURRENT_WINDOW_DAYS * Support::DAY_SECONDS
          count = ((end_time - start_time) / window_seconds).floor
          return [] unless count.positive?

          counts = Array.new(count, 0)
          rows.each do |row|
            index = ((row[:opened_at] - start_time) / window_seconds).floor
            counts[index] += 1 if index >= 0 && index < count
          end
          counts
        end

        def anomaly_row(case_type, current_count, baseline_median, ratio, z_score, basis)
          {
            'case_type'      => case_type,
            'current_count'  => current_count,
            'baseline_count' => baseline_median.round(1),
            'ratio'          => ratio.round(1),
            'z_score'        => z_score.round(2),
            'basis'          => basis,
            'severity'       => severity(ratio, z_score)
          }
        end

        def severity(ratio, z_score)
          return 'high' if ratio >= 3.0 || z_score >= 6.0

          'medium'
        end
      end
    end
  end
end
