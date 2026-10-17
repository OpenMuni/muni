require 'muni/analytics/support'

module Muni
  module Analytics
    class PoliceLogAnomalies
      CURRENT_WINDOW_DAYS = 7
      HISTORY_WEEKS = 26
      MIN_CURRENT_COUNT = 3
      MIN_BASELINE_WINDOWS = 4
      MIN_RATIO = 2.0
      MIN_Z_SCORE = 3.0

      class << self
        def compute(hall:, now: Time.now.utc)
          ds = Support.dataset(Muni::Records::PoliceLogEntry, hall)
          return warming_payload(now) unless ds

          generated_at = Support.time_value(now) || Time.now.utc
          incident = anomaly_group(ds, :occurred_at, generated_at)
          publication = anomaly_group(ds, :reported_at, generated_at)
          {
            'status'                    => 'ready',
            'generated_at'              => Support.iso_time(generated_at),
            'source_max_at'             => latest_source_at(incident, publication),
            'window_days'               => CURRENT_WINDOW_DAYS,
            'incident_source_max_at'    => incident[:source_max_at],
            'publication_source_max_at' => publication[:source_max_at],
            'incident_anomalies'        => incident[:anomalies],
            'publication_anomalies'     => publication[:anomalies],
            'anomalies'                 => incident[:anomalies] + publication[:anomalies]
          }
        end

        private

        def anomaly_group(dataset, time_field, now)
          rows = source_rows(dataset, time_field)
          latest = rows.map { |row| row[:time] }.max
          return { source_max_at: nil, anomalies: [] } unless latest

          current_start = latest - (CURRENT_WINDOW_DAYS * Support::DAY_SECONDS)
          {
            source_max_at: Support.iso_time(latest),
            anomalies:     detect(rows, current_start, latest, time_field, now)
          }
        end

        def source_rows(dataset, time_field)
          projected = dataset.select(time_field, :crime_subcategory, :crime_category)
          Support.each_row(projected).filter_map do |row|
            time = Support.time_value(row[time_field])
            next unless time

            label = Support.normalized_label(row[:crime_subcategory] || row[:crime_category])
            { label: label, time: time }
          end
        end

        def detect(rows, current_start, latest, time_field, now)
          anomalies = rows.group_by { |row| row[:label] }.filter_map do |label, grouped|
            current_count = grouped.count { |row| row[:time].between?(current_start, latest) }
            next if current_count < MIN_CURRENT_COUNT

            baseline = baseline_counts(grouped, current_start)
            next if baseline.length < MIN_BASELINE_WINDOWS

            baseline_median = Support.median(baseline).to_f
            next unless baseline_median.positive?

            ratio = current_count / baseline_median
            z_score = Support.robust_z_score(current_count, baseline)
            next if ratio < MIN_RATIO || z_score < MIN_Z_SCORE

            anomaly_row(label, current_count, baseline_median, ratio, z_score, time_field, now)
          end
          anomalies.sort_by { |row| [-row['z_score'], -row['current_count'], row['label']] }
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

        def anomaly_row(label, current_count, baseline_median, ratio, z_score, time_field, now)
          {
            'label'          => label,
            'current_count'  => current_count,
            'baseline_count' => baseline_median.round(1),
            'ratio'          => ratio.round(1),
            'z_score'        => z_score.round(2),
            'basis'          => 'rolling prior weeks',
            'time_basis'     => time_field.to_s,
            'generated_at'   => Support.iso_time(now),
            'severity'       => ratio >= 3.0 || z_score >= 6.0 ? 'high' : 'medium'
          }
        end

        def latest_source_at(*groups)
          groups.filter_map { |group| group[:source_max_at] }.max
        end

        def warming_payload(now)
          {
            'status'                => 'warming',
            'generated_at'          => Support.iso_time(now),
            'incident_anomalies'    => [],
            'publication_anomalies' => [],
            'anomalies'             => []
          }
        end
      end
    end
  end
end
