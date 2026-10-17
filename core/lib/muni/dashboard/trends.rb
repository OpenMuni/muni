module Muni
  module Dashboard
    module Trends
      def daily_trend(dataset, field, days:, now:)
        end_time, first_time = trend_bounds(dataset, field, now)
        return [] unless end_time && first_time

        start_time, count = trend_window(first_time, end_time, DAY_SECONDS, days)
        bucketed_trend(dataset, field, start_time: start_time, bucket_seconds: DAY_SECONDS, count: count)
      end

      def daily_sum_trend(dataset, time_field, value_field, days:, now:)
        end_time, first_time = trend_bounds(dataset, time_field, now)
        return [] unless end_time && first_time

        start_time, count = trend_window(first_time, end_time, DAY_SECONDS, days)
        summed_bucketed_trend(dataset, time_field, value_field,
                              start_time: start_time, bucket_seconds: DAY_SECONDS, count: count)
      end

      def weekly_trend(dataset, field, weeks:, now:)
        bucket_seconds = 7 * DAY_SECONDS
        end_time, first_time = trend_bounds(dataset, field, now)
        return [] unless end_time && first_time

        start_time, count = trend_window(first_time, end_time, bucket_seconds, weeks)
        bucketed_trend(dataset, field, start_time: start_time, bucket_seconds: bucket_seconds, count: count)
      end

      def bucketed_trend(dataset, field, start_time:, bucket_seconds:, count:)
        counts = Array.new(count, 0)
        rows = dataset.where(Sequel.lit("#{field} >= ?", start_time)).select(field).all

        rows.each do |row|
          time = time_value(row[field])
          next unless time

          index = ((time.utc - start_time) / bucket_seconds).floor
          next if index.negative? || index >= count

          counts[index] += 1
        end

        count.times.map do |index|
          bucket_start = start_time + (index * bucket_seconds)
          {
            date:  bucket_start.utc.strftime('%Y-%m-%d'),
            label: trend_label(bucket_start, bucket_seconds),
            value: counts[index]
          }
        end
      end

      def summed_bucketed_trend(dataset, time_field, value_field, start_time:, bucket_seconds:, count:)
        counts = Array.new(count, 0)
        rows = dataset.where(Sequel.lit("#{time_field} >= ?", start_time)).select(time_field, value_field).all

        rows.each do |row|
          time = time_value(row[time_field])
          next unless time

          index = ((time.utc - start_time) / bucket_seconds).floor
          next if index.negative? || index >= count

          counts[index] += row[value_field].to_i
        end

        count.times.map do |index|
          bucket_start = start_time + (index * bucket_seconds)
          {
            date:  bucket_start.utc.strftime('%Y-%m-%d'),
            label: trend_label(bucket_start, bucket_seconds),
            value: counts[index]
          }
        end
      end

      def rolling_duration_trend(dataset, bucket_field, start_field, end_field, days:, now:, window_days: 7)
        end_time, first_time = trend_bounds(dataset, bucket_field, now)
        return [] unless end_time && first_time

        start_time, count = trend_window(first_time, end_time, DAY_SECONDS, days)
        rows = duration_trend_rows(dataset, bucket_field, start_field, end_field, start_time, window_days)
        trend = count.times.map do |index|
          duration_trend_point(rows, index, start_time, bucket_field, start_field, end_field, window_days)
        end

        trim_empty_edges(trend)
      end

      def duration_trend_rows(dataset, bucket_field, start_field, end_field, start_time, window_days)
        query_start = start_time - ((window_days - 1) * DAY_SECONDS)
        dataset.where(Sequel.lit("#{bucket_field} >= ?", query_start))
               .select(bucket_field, start_field, end_field)
               .all
      end

      def duration_trend_point(rows, index, start_time, bucket_field, start_field, end_field, window_days)
        bucket_start = start_time + (index * DAY_SECONDS)
        bucket_end = bucket_start + DAY_SECONDS
        window_start = bucket_end - (window_days * DAY_SECONDS)
        durations = rows.filter_map do |row|
          bucket_time = time_value(row[bucket_field])
          next unless bucket_time && bucket_time >= window_start && bucket_time < bucket_end

          duration_seconds(row, start_field, end_field)
        end

        {
          date:  bucket_start.utc.strftime('%Y-%m-%d'),
          label: short_date_label(bucket_start),
          value: median_value(durations)&.round,
          count: durations.length
        }
      end

      def trend_bounds(dataset, field, now)
        [time_value(now) || time_value(dataset.max(field)), time_value(dataset.min(field))]
      end

      def trend_window(first_time, end_time, bucket_seconds, max_count)
        end_bucket = day_start(end_time)
        requested_start = end_bucket - ((max_count - 1) * bucket_seconds)
        start_time = [requested_start, day_start(first_time)].max

        [start_time, bucket_count(start_time, end_bucket, bucket_seconds, max_count)]
      end

      def bucket_count(start_time, end_time, bucket_seconds, max_count)
        count = ((end_time - start_time) / bucket_seconds).floor + 1
        count.clamp(0, max_count)
      end

      def trim_empty_edges(trend)
        first = trend.index { |point| point[:value] }
        last = trend.rindex { |point| point[:value] }
        return [] unless first && last

        trend[first..last]
      end

      def trend_label(time, bucket_seconds)
        label = short_date_label(time)
        bucket_seconds > DAY_SECONDS ? "Week of #{label}" : label
      end

      def short_date_label(time)
        time.utc.strftime('%b %e').gsub(/\s+/, ' ').strip
      end

      def day_start(value)
        time = time_value(value) || Time.now.utc
        Time.utc(time.utc.year, time.utc.month, time.utc.day)
      end
    end
  end
end
