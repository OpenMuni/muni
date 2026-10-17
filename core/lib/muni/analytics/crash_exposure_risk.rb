require 'muni/analytics/support'

module Muni
  module Analytics
    class CrashExposureRisk
      MAX_LOCATIONS = 50

      class << self
        def compute(hall:, now: Time.now.utc)
          crashes = crash_rows(hall)
          exposures = exposure_rows(hall)
          source_max_at = [crashes.map { |row| row[:time] }.max, exposures.map { |row| row[:time] }.max].compact.max
          return warming_payload(now) unless source_max_at

          locations = risk_locations(crashes, exposures).first(MAX_LOCATIONS)
          {
            'status'        => locations.empty? ? 'warming' : 'ready',
            'generated_at'  => Support.iso_time(now),
            'source_max_at' => Support.iso_time(source_max_at),
            'locations'     => locations
          }
        end

        private

        def warming_payload(now)
          {
            'status'       => 'warming',
            'generated_at' => Support.iso_time(now),
            'locations'    => []
          }
        end

        def crash_rows(hall)
          rows_for(Muni::Records::Crash, hall, :location_description, :occurred_at) +
            rows_for(Muni::Records::CpdCrash, hall, :location_description, :occurred_at)
        end

        def exposure_rows(hall)
          rows_for(Muni::Records::TrafficVolumeDaily, hall, :intersection, :observed_at, count_field: :count) +
            rows_for(Muni::Records::BicycleCount, hall, :count_location, :observed_at, count_field: :count) +
            rows_for(Muni::Records::PedestrianCountDaily, hall, :intersection, :observed_at, count_field: :count)
        end

        def rows_for(record_class, hall, label_field, time_field, count_field: nil)
          ds = Support.dataset(record_class, hall)
          return [] unless ds

          fields = [:location, label_field, time_field]
          fields << count_field if count_field
          Support.each_row(ds.select(*fields.uniq)).filter_map do |row|
            time = Support.time_value(row[time_field])
            label = Support.presence(row[label_field])
            key = location_key(row[:location], label)
            next unless time && key

            { key: key, label: label || key, time: time, count: count_field ? row[count_field].to_i : 1 }
          end
        end

        def risk_locations(crashes, exposures)
          exposure_by_key = exposures.group_by { |row| row[:key] }.transform_values do |rows|
            rows.sum { |row| row[:count].to_i }
          end
          locations = crashes.group_by { |row| row[:key] }.filter_map do |key, grouped|
            exposure = exposure_by_key[key].to_i
            next unless exposure.positive?

            count = grouped.length
            {
              'key'             => key,
              'label'           => grouped.first[:label],
              'crash_count'     => count,
              'exposure_count'  => exposure,
              'risk_per_10k'    => ((count.to_f / exposure) * 10_000).round(2),
              'latest_crash_at' => Support.iso_time(grouped.map { |row| row[:time] }.max)
            }
          end

          locations.sort_by { |row| [-row['risk_per_10k'], -row['crash_count'], row['label']] }
        end

        def location_key(point_value, label)
          point = Support.point_value(point_value)
          return "point:#{point.map { |value| value.round(4) }.join(',')}" if point

          text = Support.presence(label)
          return nil unless text

          text.downcase.gsub(/[^a-z0-9]+/, ' ').strip
        end
      end
    end
  end
end
