require 'digest'
require 'muni/local_time'

module Muni
  module View
    module FoodTruckStatus
      NON_SURFACEABLE_FOOD_TRUCK_TEXT = /
        \b(
          as\s+needed|as\s+hired|private\s+events?|public\s+events?|specific\s+events?|
          catering|client\s+contracts?|varies|various|tbd|to\s+be\s+determined|
          seasonal|not\s+sure|unknown|permitted\s+hours?|permit\s+needed|
          none\s+as\s+of\s+now
        )\b
      /ix

      def open_food_truck_pairs(pairs, now: Time.now.utc)
        pairs.select { |row, _source| food_truck_open_now?(row, now: now) }
      end

      def surfaceable_food_truck_pairs(pairs)
        pairs.select { |row, _source| surfaceable_food_truck_stop?(row) }
             .sort_by { |row, _source| -food_truck_sort_time(row).to_f }
             .uniq { |row, _source| food_truck_surface_key(row) }
      end

      def surfaceable_food_truck_stop?(row)
        food_truck_schedule_present?(row) &&
          food_truck_hours_parseable?(row) &&
          food_truck_location_present?(row) &&
          food_truck_text_surfaceable?(row)
      end

      def food_truck_business_id(row)
        identity = food_truck_identity_value(row)
        "food-truck-business/#{Digest::SHA256.hexdigest(identity)[0, 16]}"
      end

      def food_truck_open_now?(row, now: Time.now.utc)
        return false unless row.respond_to?(:weekday)

        local = cambridge_local_time(now)
        return false unless row.weekday.to_s.casecmp?(local.strftime('%A'))

        opens = clock_minutes(row.respond_to?(:open_time) ? row.open_time : nil)
        closes = clock_minutes(row.respond_to?(:close_time) ? row.close_time : nil)
        return false unless opens && closes

        current = (local.hour * 60) + local.min
        return true if opens == closes

        if opens < closes
          current >= opens && current < closes
        else
          current >= opens || current < closes
        end
      end

      def cambridge_local_time(time)
        Muni::LocalTime.local_time(time, city: 'cambridge')
      end

      private

      def food_truck_schedule_present?(row)
        row.respond_to?(:weekday) &&
          !blank_food_truck_value?(row.weekday) &&
          !blank_food_truck_value?(row.respond_to?(:hours) ? row.hours : nil) &&
          !blank_food_truck_value?(row.respond_to?(:address) ? row.address : nil)
      end

      def food_truck_hours_parseable?(row)
        opens = clock_minutes(row.respond_to?(:open_time) ? row.open_time : nil)
        closes = clock_minutes(row.respond_to?(:close_time) ? row.close_time : nil)
        !!(opens && closes)
      end

      def food_truck_location_present?(row)
        location = row.respond_to?(:location) ? row.location : nil
        location.is_a?(Array) && location.length >= 2
      end

      def food_truck_text_surfaceable?(row)
        !non_surfaceable_food_truck_text?(row.hours) &&
          !non_surfaceable_food_truck_text?(row.address)
      end

      def food_truck_surface_key(row)
        [
          normalized_food_truck_value(row.respond_to?(:truck_name) ? row.truck_name : nil),
          normalized_food_truck_value(row.respond_to?(:dba) ? row.dba : nil),
          normalized_food_truck_value(row.respond_to?(:business_name) ? row.business_name : nil),
          normalized_food_truck_value(row.weekday),
          normalized_food_truck_value(row.respond_to?(:address) ? row.address : nil),
          normalized_food_truck_value(row.respond_to?(:open_time) ? row.open_time : nil),
          normalized_food_truck_value(row.respond_to?(:close_time) ? row.close_time : nil)
        ].join('|')
      end

      def food_truck_identity_value(row)
        %i[truck_name dba business_name permit_id viewpoint_id external_id].filter_map do |field|
          next unless row.respond_to?(field)

          normalized = normalized_food_truck_value(row.public_send(field))
          normalized unless normalized.empty?
        end.first || 'unknown-food-truck'
      end

      def food_truck_sort_time(row)
        %i[issued_at applicant_submit_date attested_at collected_at last_seen_at].each do |field|
          return row.public_send(field) if row.respond_to?(field) && row.public_send(field)
        end
        Time.at(0)
      end

      def non_surfaceable_food_truck_text?(value)
        normalized_food_truck_value(value).match?(NON_SURFACEABLE_FOOD_TRUCK_TEXT)
      end

      def blank_food_truck_value?(value)
        normalized_food_truck_value(value).empty?
      end

      def normalized_food_truck_value(value)
        value.to_s.tr("\u00A0", ' ').gsub(/\s+/, ' ').strip.downcase
      end

      def clock_minutes(value)
        match = value.to_s.strip.match(/\A(\d{1,2})(?::(\d{2}))?\s*([AP])M\z/i)
        return nil unless match

        hour = match[1].to_i % 12
        hour += 12 if match[3].casecmp?('P')
        minute = match[2].to_i
        return nil unless minute.between?(0, 59)

        (hour * 60) + minute
      end
    end
  end
end
