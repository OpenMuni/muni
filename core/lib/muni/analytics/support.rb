require 'json'
require 'time'

module Muni
  module Analytics
    module Support
      DAY_SECONDS = 86_400
      MIN_BUCKET_SAMPLES = 3
      MIN_KEYWORD_SAMPLES = 8
      STOPWORDS = %w[
        about after all and are because been but can cannot could did does for from had has have
        her him his into its just like not now our out over she the their them then there they
        this too was were what when where who why with you your
      ].freeze

      module_function

      def dataset(record_class, hall)
        table = record_class.table_name.to_sym
        return nil unless Muni::Store.db.table_exists?(table)

        Muni::Store.db[table].where(hall: hall).order(:external_id)
      end

      # Iterate projected datasets in bounded pages. Analytics callers should
      # select only the fields they need before passing a dataset here.
      def each_row(dataset, batch_size: 1_000, &block)
        return enum_for(__method__, dataset, batch_size: batch_size) unless block_given?

        offset = 0
        loop do
          page = dataset.limit(batch_size, offset).all
          page.each(&block)
          break if page.length < batch_size

          offset += page.length
        end
      end

      def time_value(value)
        if value.is_a?(Time)
          return Time.utc(value.year, value.month, value.day, value.hour, value.min, value.sec + value.subsec)
        end
        return value.to_time.utc if value.respond_to?(:to_time)
        return nil if value.nil?

        Time.parse(value.to_s).utc
      rescue ArgumentError
        nil
      end

      def iso_time(value)
        time_value(value)&.iso8601
      end

      def presence(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def normalized_label(value)
        presence(value)&.gsub(/\s+/, ' ') || 'Unknown'
      end

      def key_for(parts)
        parts.map { |name, value| "#{name}=#{normalized_label(value).downcase}" }.join('|')
      end

      def citywide_key
        'citywide'
      end

      def duration_seconds(row, start_field, end_field)
        start_time = time_value(row[start_field])
        end_time = time_value(row[end_field])
        return nil unless start_time && end_time && end_time >= start_time

        end_time - start_time
      end

      def percentile(values, percentile)
        sorted = values.compact.map(&:to_f).sort
        return nil if sorted.empty?
        return sorted.first if sorted.length == 1

        rank = (percentile.to_f / 100) * (sorted.length - 1)
        lower = sorted[rank.floor]
        upper = sorted[rank.ceil]
        lower + ((upper - lower) * (rank - rank.floor))
      end

      def median(values)
        percentile(values, 50)
      end

      def bucket_stats(values)
        durations = values.compact.map(&:to_f).select(&:positive?).sort
        return nil if durations.empty?

        {
          'count'       => durations.length,
          'median_days' => days(percentile(durations, 50)),
          'low_days'    => days(percentile(durations, 10)),
          'high_days'   => days(percentile(durations, 90))
        }
      end

      def days(seconds)
        value = seconds.to_f / DAY_SECONDS
        value < 1 ? value.round(2) : value.round(1)
      end

      def tokenize(text)
        text.to_s.downcase.scan(/[a-z][a-z0-9]{2,}/)
            .reject { |token| STOPWORDS.include?(token) }
            .uniq
            .first(20)
      end

      def valuation_bucket(value)
        amount = value.to_f
        return 'unknown' unless amount.positive?

        case amount
        when 0...10_000 then 'under_10k'
        when 10_000...50_000 then '10k_50k'
        when 50_000...250_000 then '50k_250k'
        when 250_000...1_000_000 then '250k_1m'
        else 'over_1m'
        end
      end

      def point_value(value)
        point = value.is_a?(String) ? JSON.parse(value) : value
        return nil unless point.is_a?(Array) && point.length >= 2

        lon = Float(point[0])
        lat = Float(point[1])
        [lon, lat]
      rescue JSON::ParserError, ArgumentError, TypeError
        nil
      end

      def truthy?(value)
        value == true || value.to_s == '1' || value.to_s.downcase == 'true'
      end

      def robust_z_score(value, baseline_values)
        values = baseline_values.compact.map(&:to_f)
        return 0.0 if values.empty?

        center = median(values)
        deviations = values.map { |entry| (entry - center).abs }
        mad = median(deviations).to_f
        return (0.6745 * (value.to_f - center) / mad).round(2) if mad.positive?

        value.to_f > center.to_f ? 99.0 : 0.0
      end

      def clamp(value, min, max)
        value.clamp(min, max)
      end
    end
  end
end
