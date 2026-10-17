require 'muni/analytics/support'

module Muni
  module Analytics
    class PermitProcessing
      class << self
        def train(hall:, now: Time.now.utc)
          ds = Support.dataset(Muni::Records::BuildingPermit, hall)
          return warming_payload(now) unless ds

          rows = Support.each_row(
            ds.exclude(applied_at: nil, issued_at: nil)
              .select(:permit_type, :property_use, :declared_valuation, :applied_at, :issued_at)
          )
          durations_by_key = Hash.new { |hash, key| hash[key] = [] }
          source_max_at = nil

          rows.each do |row|
            duration = Support.duration_seconds(row, :applied_at, :issued_at)
            issued_at = Support.time_value(row[:issued_at])
            next unless duration

            source_max_at = [source_max_at, issued_at].compact.max
            feature_keys(row).each { |key| durations_by_key[key] << duration }
          end

          buckets = compact_stats(durations_by_key)
          citywide = buckets[Support.citywide_key]
          {
            'status'             => citywide ? 'ready' : 'warming',
            'generated_at'       => Support.iso_time(now),
            'source_max_at'      => Support.iso_time(source_max_at),
            'sample_size'        => citywide ? citywide['count'] : 0,
            'min_bucket_samples' => Support::MIN_BUCKET_SAMPLES,
            'citywide'           => citywide,
            'buckets'            => buckets
          }
        end

        def predict(model, attrs)
          payload = model_payload_from(model)
          return warming_prediction unless ready?(payload)

          base = best_bucket(payload, attrs)
          return warming_prediction unless base

          {
            status:               'ready',
            predicted_days:       base['median_days'],
            range_days:           { low: base['low_days'], high: base['high_days'] },
            sample_size:          base['count'],
            basis:                base['basis'],
            generated_at:         payload['generated_at'],
            source_max_at:        payload['source_max_at'],
            contributing_factors: [
              { name: 'Historical bucket', value: base['basis'], sample_size: base['count'] }
            ]
          }
        end

        private

        def warming_payload(now)
          {
            'status'       => 'warming',
            'generated_at' => Support.iso_time(now),
            'sample_size'  => 0,
            'buckets'      => {}
          }
        end

        def compact_stats(groups)
          groups.each_with_object({}) do |(key, values), out|
            stats = Support.bucket_stats(values)
            out[key] = stats if stats
          end
        end

        def feature_keys(row)
          type = Support.normalized_label(row[:permit_type])
          use = Support.normalized_label(row[:property_use])
          valuation = Support.valuation_bucket(row[:declared_valuation])

          [
            Support.key_for(permit_type: type, property_use: use, valuation: valuation),
            Support.key_for(permit_type: type, property_use: use),
            Support.key_for(permit_type: type),
            Support.key_for(property_use: use),
            Support.key_for(valuation: valuation),
            Support.citywide_key
          ]
        end

        def prediction_keys(attrs)
          type = attrs[:permit_type] || attrs['permit_type']
          use = attrs[:property_use] || attrs['property_use']
          valuation = Support.valuation_bucket(attrs[:declared_valuation] || attrs['declared_valuation'])

          [
            ['permit type, property use, valuation bucket',
             Support.key_for(permit_type: type, property_use: use, valuation: valuation)],
            ['permit type and property use', Support.key_for(permit_type: type, property_use: use)],
            ['permit type', Support.key_for(permit_type: type)],
            ['property use', Support.key_for(property_use: use)],
            ['valuation bucket', Support.key_for(valuation: valuation)],
            ['citywide issued permits', Support.citywide_key]
          ]
        end

        def best_bucket(payload, attrs)
          prediction_keys(attrs).each do |basis, key|
            stats = payload.dig('buckets', key)
            next unless stats
            next if stats['count'].to_i < Support::MIN_BUCKET_SAMPLES && key != Support.citywide_key

            return stats.merge('basis' => basis)
          end
          payload['citywide']&.merge('basis' => 'citywide issued permits')
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
