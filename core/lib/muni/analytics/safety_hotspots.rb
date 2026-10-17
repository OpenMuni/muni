require 'muni/analytics/support'

module Muni
  module Analytics
    class SafetyHotspots
      MAX_LOCATIONS = 50

      SOURCES = [
        [-> { Muni::Records::PoliceLogEntry }, :reported_at, :crime_subcategory, 'police_log'],
        [-> { Muni::Records::CrimeReport }, :reported_at, :crime_category, 'crime'],
        [-> { Muni::Records::DispatchCall }, :received_at, :incident_type, 'dispatch'],
        [-> { Muni::Records::CpdCrash }, :occurred_at, :location_description, 'recent_crash']
      ].freeze

      class << self
        def compute(hall:, now: Time.now.utc)
          rows = source_rows(hall)
          source_max_at = rows.map { |row| row[:time] }.compact.max
          return warming_payload(now) unless source_max_at

          groups = Hash.new { |hash, key| hash[key] = empty_group(key) }
          rows.each { |row| add_row(groups, row, source_max_at) }
          locations = normalize_scores(groups.values).first(MAX_LOCATIONS)

          {
            'status'        => locations.empty? ? 'warming' : 'ready',
            'generated_at'  => Support.iso_time(now),
            'source_max_at' => Support.iso_time(source_max_at),
            'locations'     => locations
          }
        end

        private

        def source_rows(hall)
          SOURCES.flat_map do |record_ref, time_field, type_field, kind|
            record_class = record_ref.call
            ds = Support.dataset(record_class, hall)
            next [] unless ds

            projected = ds.select(:location, :neighborhood, time_field, type_field)
            Support.each_row(projected).filter_map do |row|
              time = Support.time_value(row[time_field])
              next unless time

              {
                kind:         kind,
                type:         Support.normalized_label(row[type_field]),
                neighborhood: Support.presence(row[:neighborhood]),
                location:     Support.point_value(row[:location]),
                time:         time
              }
            end
          end
        end

        def warming_payload(now)
          {
            'status'       => 'warming',
            'generated_at' => Support.iso_time(now),
            'locations'    => []
          }
        end

        def empty_group(key)
          {
            key:       key,
            label:     nil,
            location:  nil,
            raw_score: 0.0,
            count:     0,
            latest_at: nil,
            by_kind:   Hash.new(0),
            by_type:   Hash.new(0)
          }
        end

        def add_row(groups, row, anchor)
          key, label, location = location_key(row)
          return unless key

          group = groups[key]
          group[:label] ||= label
          group[:location] ||= location
          group[:count] += 1
          group[:latest_at] = [group[:latest_at], row[:time]].compact.max
          group[:by_kind][row[:kind]] += 1
          group[:by_type][row[:type]] += 1
          group[:raw_score] += recency_weight(row[:time], anchor) * kind_weight(row[:kind])
        end

        def location_key(row)
          point = row[:location]
          if point
            rounded = point.map { |value| value.round(4) }
            return ["point:#{rounded[0]},#{rounded[1]}", point_label(rounded), rounded]
          end

          label = row[:neighborhood]
          return nil unless label

          ["neighborhood:#{label.downcase}", label, nil]
        end

        def recency_weight(time, anchor)
          age_days = [(anchor - time) / Support::DAY_SECONDS, 0].max
          0.5**(age_days / 180.0)
        end

        def kind_weight(kind)
          case kind
          when 'recent_crash' then 1.6
          when 'dispatch' then 1.2
          else 1.0
          end
        end

        def normalize_scores(groups)
          max_score = groups.map { |group| group[:raw_score] }.max.to_f
          return [] unless max_score.positive?

          groups.sort_by { |group| [-group[:raw_score], -group[:count], group[:key]] }.map do |group|
            {
              'key'       => group[:key],
              'label'     => group[:label] || 'Unknown location',
              'location'  => group[:location],
              'score'     => ((group[:raw_score] / max_score) * 100).round,
              'count'     => group[:count],
              'latest_at' => Support.iso_time(group[:latest_at]),
              'by_kind'   => sorted_counts(group[:by_kind]),
              'by_type'   => sorted_counts(group[:by_type]).first(5)
            }
          end
        end

        def point_label(location)
          "#{location[1].round(4)}, #{location[0].round(4)}"
        end

        def sorted_counts(counts)
          counts.sort_by { |name, count| [-count, name] }
                .map { |name, count| { 'name' => name, 'count' => count } }
        end
      end
    end
  end
end
