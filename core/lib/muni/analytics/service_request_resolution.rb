require 'muni/analytics/support'

module Muni
  module Analytics
    class ServiceRequestResolution
      class << self
        def train(hall:, now: Time.now.utc)
          ds = Support.dataset(Muni::Records::ServiceRequest, hall)
          return warming_payload(now) unless ds

          rows = Support.each_row(
            ds.exclude(opened_at: nil, closed_at: nil)
              .select(:case_type, :department, :neighborhood, :description, :opened_at, :closed_at)
          )
          durations_by_key = Hash.new { |hash, key| hash[key] = [] }
          durations_by_keyword = Hash.new { |hash, key| hash[key] = [] }
          source_max_at = nil

          rows.each do |row|
            duration = Support.duration_seconds(row, :opened_at, :closed_at)
            opened_at = Support.time_value(row[:opened_at])
            closed_at = Support.time_value(row[:closed_at])
            next unless duration && opened_at

            source_max_at = [source_max_at, closed_at || opened_at].compact.max
            feature_keys(row, opened_at).each { |key| durations_by_key[key] << duration }
            Support.tokenize(row[:description]).each { |token| durations_by_keyword[token] << duration }
          end

          model_payload(
            now:                  now,
            source_max_at:        source_max_at,
            durations_by_key:     durations_by_key,
            durations_by_keyword: durations_by_keyword
          )
        end

        def predict(model, attrs)
          payload = model_payload_from(model)
          return warming_prediction unless ready?(payload)

          opened_at = Support.time_value(attrs[:opened_at] || attrs['opened_at']) || Time.now.utc
          base = best_bucket(payload, attrs, opened_at)
          return warming_prediction unless base

          keyword_match = keyword_adjustment(payload, attrs[:description] || attrs['description'], base)
          predicted = Support.clamp(base['median_days'].to_f + keyword_match[:adjustment], 0.1, 3650)
          {
            status:               'ready',
            predicted_days:       predicted.round(1),
            range_days:           shifted_range(base, keyword_match[:adjustment]),
            sample_size:          base['count'],
            basis:                base['basis'],
            generated_at:         payload['generated_at'],
            source_max_at:        payload['source_max_at'],
            contributing_factors: factors(base, keyword_match)
          }
        end

        private

        def warming_payload(now)
          {
            'status'       => 'warming',
            'generated_at' => Support.iso_time(now),
            'sample_size'  => 0,
            'buckets'      => {},
            'keywords'     => {}
          }
        end

        def model_payload(now:, source_max_at:, durations_by_key:, durations_by_keyword:)
          buckets = compact_stats(durations_by_key)
          keywords = compact_stats(durations_by_keyword, min_count: Support::MIN_KEYWORD_SAMPLES)
          citywide = buckets[Support.citywide_key]
          status = citywide ? 'ready' : 'warming'

          {
            'status'             => status,
            'generated_at'       => Support.iso_time(now),
            'source_max_at'      => Support.iso_time(source_max_at),
            'sample_size'        => citywide ? citywide['count'] : 0,
            'min_bucket_samples' => Support::MIN_BUCKET_SAMPLES,
            'citywide'           => citywide,
            'buckets'            => buckets,
            'keywords'           => keywords
          }
        end

        def compact_stats(groups, min_count: 1)
          groups.each_with_object({}) do |(key, values), out|
            next if values.length < min_count

            stats = Support.bucket_stats(values)
            out[key] = stats if stats
          end
        end

        def feature_keys(row, opened_at)
          type = Support.normalized_label(row[:case_type])
          department = Support.normalized_label(row[:department])
          neighborhood = Support.normalized_label(row[:neighborhood])
          weekday = opened_at.strftime('%A')

          [
            Support.key_for(case_type: type, department: department, neighborhood: neighborhood, weekday: weekday),
            Support.key_for(case_type: type, department: department, neighborhood: neighborhood),
            Support.key_for(case_type: type, department: department),
            Support.key_for(case_type: type),
            Support.key_for(department: department),
            Support.citywide_key
          ]
        end

        def prediction_keys(attrs, opened_at)
          type = attrs[:case_type] || attrs['case_type']
          department = attrs[:department] || attrs['department']
          neighborhood = attrs[:neighborhood] || attrs['neighborhood']
          weekday = opened_at.strftime('%A')

          [
            ['case type, department, neighborhood, weekday',
             Support.key_for(case_type: type, department: department, neighborhood: neighborhood, weekday: weekday)],
            ['case type, department, neighborhood',
             Support.key_for(case_type: type, department: department, neighborhood: neighborhood)],
            ['case type and department', Support.key_for(case_type: type, department: department)],
            ['case type', Support.key_for(case_type: type)],
            ['department', Support.key_for(department: department)],
            ['citywide closed 311 cases', Support.citywide_key]
          ]
        end

        def best_bucket(payload, attrs, opened_at)
          prediction_keys(attrs, opened_at).each do |basis, key|
            stats = payload.dig('buckets', key)
            next unless stats
            next if stats['count'].to_i < Support::MIN_BUCKET_SAMPLES && key != Support.citywide_key

            return stats.merge('basis' => basis)
          end
          payload['citywide']&.merge('basis' => 'citywide closed 311 cases')
        end

        def keyword_adjustment(payload, description, base)
          tokens = Support.tokenize(description)
          matches = tokens.filter_map do |token|
            stats = payload.dig('keywords', token)
            stats&.merge('keyword' => token)
          end
          return { adjustment: 0.0, adjusted: [], mentioned: tokens.first(5) } if matches.empty?

          citywide_median = payload.dig('citywide', 'median_days').to_f
          raw_adjustment = matches.sum { |stats| stats['median_days'].to_f - citywide_median } / matches.length
          max_adjustment = base['median_days'].to_f * 0.3
          {
            adjustment: Support.clamp(raw_adjustment, -max_adjustment, max_adjustment),
            adjusted:   matches.first(5),
            mentioned:  tokens.first(5)
          }
        end

        def shifted_range(base, adjustment)
          low = Support.clamp(base['low_days'].to_f + adjustment, 0.1, 3650)
          high = Support.clamp(base['high_days'].to_f + adjustment, low, 3650)
          { low: low.round(1), high: high.round(1) }
        end

        def factors(base, keyword_match)
          list = [
            { name: 'Historical bucket', value: base['basis'], sample_size: base['count'] }
          ]
          unless keyword_match[:adjusted].empty?
            list << {
              name:  'Description keywords',
              value: keyword_match[:adjusted].map { |stats| stats['keyword'] }.join(', ')
            }
          end
          if keyword_match[:adjusted].empty? && keyword_match[:mentioned].any?
            list << { name: 'Description keywords', value: keyword_match[:mentioned].join(', ') }
          end
          list
        end

        def model_payload_from(model)
          model.is_a?(Hash) && model.key?(:payload) ? model[:payload] : model
        end

        def ready?(payload)
          payload.is_a?(Hash) && payload['status'] == 'ready' && payload['citywide']
        end

        def warming_prediction
          {
            status:               'warming',
            predicted_days:       nil,
            range_days:           nil,
            sample_size:          0,
            basis:                nil,
            contributing_factors: []
          }
        end
      end
    end
  end
end
