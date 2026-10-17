require 'muni/analytics/support'

module Muni
  module Analytics
    class CrashRisk
      MAX_LOCATIONS = 50

      class << self
        def compute(hall:, now: Time.now.utc)
          ds = Support.dataset(Muni::Records::Crash, hall)
          return warming_payload(now) unless ds

          projected = ds.select(:crash_type, :injury, :fatal, :cyclist, :pedestrian,
                                :location_description, :location, :occurred_at)
          source_max_at = Support.each_row(projected).filter_map do |row|
            Support.time_value(row[:occurred_at])
          end.max
          anchor = source_max_at || now
          groups = Hash.new { |hash, key| hash[key] = empty_group(key) }

          Support.each_row(projected).each do |row|
            occurred_at = Support.time_value(row[:occurred_at])
            key, location = location_key(row)
            next unless key && occurred_at

            add_crash(groups[key], row, location, occurred_at, anchor)
          end

          locations = normalize_scores(groups.values).first(MAX_LOCATIONS)
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

        def empty_group(key)
          {
            key:              key,
            label:            nil,
            location:         nil,
            raw_score:        0.0,
            crash_count:      0,
            injury_count:     0,
            fatal_count:      0,
            cyclist_count:    0,
            pedestrian_count: 0,
            latest_at:        nil
          }
        end

        def location_key(row)
          point = Support.point_value(row[:location])
          if point
            rounded = point.map { |value| value.round(4) }
            return ["point:#{rounded[0]},#{rounded[1]}", rounded]
          end

          text = Support.presence(row[:location_description])
          normalized = normalize_location_text(text)
          return nil unless normalized && normalized.length >= 5

          ["description:#{normalized}", nil]
        end

        def add_crash(group, row, location, occurred_at, anchor)
          group[:label] ||= Support.presence(row[:location_description]) || point_label(location)
          group[:location] ||= location
          group[:crash_count] += 1
          group[:injury_count] += 1 if Support.truthy?(row[:injury])
          group[:fatal_count] += 1 if Support.truthy?(row[:fatal])
          group[:cyclist_count] += 1 if Support.truthy?(row[:cyclist])
          group[:pedestrian_count] += 1 if Support.truthy?(row[:pedestrian])
          group[:latest_at] = [group[:latest_at], occurred_at].compact.max
          group[:raw_score] += recency_weight(occurred_at, anchor) * severity_weight(row)
        end

        def recency_weight(occurred_at, anchor)
          age_days = [(anchor - occurred_at) / Support::DAY_SECONDS, 0].max
          0.5**(age_days / 365.0)
        end

        def severity_weight(row)
          weight = 1.0
          weight += 1.5 if Support.truthy?(row[:injury])
          weight += 5.0 if Support.truthy?(row[:fatal])
          weight += 1.25 if Support.truthy?(row[:cyclist])
          weight += 1.25 if Support.truthy?(row[:pedestrian])
          weight
        end

        def normalize_scores(groups)
          max_score = groups.map { |group| group[:raw_score] }.max.to_f
          return [] unless max_score.positive?

          groups.sort_by { |group| [-group[:raw_score], -group[:crash_count], group[:key]] }.map do |group|
            score = ((group[:raw_score] / max_score) * 100).round
            {
              'key'              => group[:key],
              'label'            => group[:label] || 'Unknown location',
              'location'         => group[:location],
              'score'            => score,
              'crash_count'      => group[:crash_count],
              'injury_count'     => group[:injury_count],
              'fatal_count'      => group[:fatal_count],
              'cyclist_count'    => group[:cyclist_count],
              'pedestrian_count' => group[:pedestrian_count],
              'latest_at'        => Support.iso_time(group[:latest_at]),
              'factors'          => factors(group)
            }
          end
        end

        def point_label(location)
          return nil unless location

          "#{location[1].round(4)}, #{location[0].round(4)}"
        end

        def normalize_location_text(text)
          return nil unless text

          text.downcase.gsub(/[^a-z0-9]+/, ' ').strip
        end

        def factors(group)
          factors = []
          factors << "#{group[:crash_count]} crashes"
          factors << "#{group[:injury_count]} injury" if group[:injury_count].positive?
          factors << "#{group[:fatal_count]} fatal" if group[:fatal_count].positive?
          factors << "#{group[:cyclist_count]} cyclist" if group[:cyclist_count].positive?
          factors << "#{group[:pedestrian_count]} pedestrian" if group[:pedestrian_count].positive?
          factors
        end
      end
    end
  end
end
