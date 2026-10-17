require_relative '_shared'
require_relative 'location_resolver'
require 'date'
require 'digest'

module Cambridge
  class FoodTrucks < Muni::Source
    include Cambridge::SharedSoda

    source :food_trucks,
           hall:     'cambridge',
           emits:    Muni::Records::FoodTruck,
           base_url: SharedSoda::BASE_URL,
           auth:     :app_token

    RESOURCE = ENV.fetch('CAMBRIDGE_FOOD_TRUCKS_RESOURCE', 'qweb-m8r8').freeze
    CURRENT_DAYS = ENV.fetch('CAMBRIDGE_FOOD_TRUCKS_CURRENT_DAYS', '548').to_i
    WEEKDAYS = %w[monday tuesday wednesday thursday friday saturday sunday].freeze
    VAGUE_LOCATION = /
      \b(
        various|multiple|around\scambridge|citywide|city-wide|private\sevents?|
        public\sevents?|as\srequested|construction\ssites?|neighbou?rhoods?|
        catering|tbd|to\sbe\sdetermined
      )\b
    /ix
    UNAVAILABLE = %r{\A(?:n[/.]?\s*/?\s*a|none(?:\s+as\s+of\s+now)?|no|closed|tbd|to be determined|-+)\z}i

    def pull(since: nil, limit: 500) # rubocop:disable Lint/UnusedMethodArgument
      rows = socrata.query(resource: RESOURCE, where: current_window, order: 'issue_date DESC, id DESC', limit: limit)
      rows.flat_map { |row| normalize_records(row) }
    end

    def cursor_time(record)
      record.issued_at || record.applicant_submit_date || record.attested_at
    end

    private

    def current_window
      floor = Time.now.utc - (CURRENT_DAYS * 86_400)
      "issue_date >= '#{soql_since(floor)}'"
    end

    def normalize_records(row)
      records = WEEKDAYS.filter_map do |day|
        hours = clean_schedule(row["hours_of_operation_#{day}"])
        address = clean_location(row["location_of_food_truck_#{day}"])
        next if hours.nil? && address.nil?

        build_record(row, weekday_label(day), hours, address)
      end

      records.empty? ? [build_record(row, nil, nil, nil)] : records
    end

    def build_record(row, weekday, hours, address)
      emit(
        identity_attrs(row)
          .merge(schedule_attrs(row, weekday, hours, address))
          .merge(date_attrs(row))
          .merge(location_attrs(address))
      )
    end

    def identity_attrs(row)
      {
        hall:                 'cambridge',
        status:               clean_string(row['status']),
        permit_id:            clean_string(row['id']),
        viewpoint_id:         clean_string(row['viewpoint_id']),
        business_name:        clean_string(row['business_name']),
        dba:                  clean_string(row['dba']),
        truck_name:           truck_name(row),
        items_to_be_sold:     clean_list_text(row['items_to_be_sold']),
        equipment:            clean_list_text(row['equipment']),
        refrigeration_method: clean_string(row['refrigeration_method']),
        soft_serve_machine:   clean_string(row['soft_serve_machine']),
        food_handler_count:   integer(row['food_handler_count']),
        sanitizer_type:       clean_string(row['sanitizer_type']),
        business_address:     clean_string(row['business_address']),
        prep_location:        clean_string(row['location_off_site_food_prep']),
        toilet_facilities:    clean_string(row['location_of_toilet_facilities'])
      }
    end

    def schedule_attrs(row, weekday, hours, address)
      open_time, close_time = parse_hours(hours)
      {
        external_id: external_id(row, weekday, hours, address),
        weekday:     weekday,
        hours:       hours,
        open_time:   open_time,
        close_time:  close_time,
        address:     address
      }
    end

    def date_attrs(row)
      {
        applicant_submit_date:                       parse_date(row['applicant_submit_date']),
        issued_at:                                   parse_date(row['issue_date']),
        food_protection_certification_expires_at:    parse_date(row['food_protection_certification']),
        allergen_awareness_certification_expires_at: parse_date(row['allergen_awareness']),
        attested_at:                                 parse_date(row['attestat_date'])
      }
    end

    def location_attrs(address)
      {
        location:   point(address),
        source_url: dataset_url
      }
    end

    def external_id(row, weekday, hours, address)
      base = clean_string(row['id']) || clean_string(row['viewpoint_id']) || row_digest(row)
      date = parse_date(row['issue_date'] || row['applicant_submit_date'])
      date_key = date ? date.utc.strftime('%Y%m%d') : 'undated'
      day_key = weekday ? weekday.downcase : 'permit'
      stop_key = Digest::SHA256.hexdigest([hours, address].compact.join('|'))[0, 8]
      "food-truck/#{base}/#{date_key}/#{day_key}/#{stop_key}"
    end

    def row_digest(row)
      Digest::SHA256.hexdigest(row.sort.to_h.to_s)[0, 16]
    end

    def truck_name(row)
      clean_string(row['mobile_food_truck_name'] || row['dba'] || row['business_name'])
    end

    def weekday_label(day)
      day.capitalize
    end

    def clean_schedule(value)
      text = clean_string(value)
      return nil if unavailable?(text)

      compact_text(text).gsub(/[–—]/, '-')
    end

    def clean_location(value)
      text = clean_string(value)
      return nil if unavailable?(text)

      compact_text(text)
    end

    def compact_text(text)
      text.tr("\u00A0", ' ')
          .gsub(/\s+/, ' ')
          .strip
    end

    def clean_list_text(value)
      text = value.to_s
                  .tr("\u00A0", ' ')
                  .gsub(/\r\n?|\n/, ', ')
                  .gsub(/\s*,\s*/, ', ')
                  .gsub(/\s+/, ' ')
                  .strip
      text.empty? ? nil : text
    end

    def unavailable?(text)
      text.nil? || text.match?(UNAVAILABLE)
    end

    def integer(value)
      return nil if value.nil? || value.to_s.strip.empty?

      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def parse_time(value)
      Muni::Helpers::Normalize.parse_time(value)
    end

    def parse_date(value)
      text = clean_string(value)
      return nil unless text

      date = Date.parse(text)
      Time.utc(date.year, date.month, date.day)
    rescue ArgumentError, TypeError
      parse_time(value)
    end

    def parse_hours(hours)
      return [nil, nil] unless hours

      text = hours.tr(';', ':')
                  .gsub(/\*+/, ' ')
                  .gsub(/\b(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)\s*:\s*/i, '')
                  .gsub(/\bstarting\s+in\s+\w+\b/i, ' ')
                  .gsub(/\s+/, ' ')
                  .strip
      parts = text.split(/\s*(?:-| to )\s*/i, 2)
      return [nil, nil] unless parts.length == 2

      end_meridiem = meridiem(parts[1]) || inferred_end_meridiem(parts[0], parts[1])
      start_meridiem = meridiem(parts[0]) || inferred_start_meridiem(parts[0], parts[1], end_meridiem)
      [clock(parts[0], fallback_meridiem: start_meridiem), clock(parts[1], fallback_meridiem: end_meridiem)]
    end

    def clock(value, fallback_meridiem: nil)
      match = value.to_s.strip.match(/\A(\d{1,2})(?::\s*(\d{2}))?\s*([ap](?:\.?m\.?)?)?\z/i)
      return nil unless match

      hour = match[1].to_i
      minute = (match[2] || '00').to_i
      meridiem = match[3] ? meridiem(match[3]) : fallback_meridiem
      return nil unless hour.between?(1, 12) && minute.between?(0, 59) && meridiem

      "#{hour}:#{minute.to_s.rjust(2, '0')} #{meridiem}"
    end

    def meridiem(value)
      match = value.to_s.match(/([ap])(?:\.?m\.?)?/i)
      return nil unless match

      match[1].casecmp?('a') ? 'AM' : 'PM'
    end

    def inferred_start_meridiem(start_value, end_value, end_meridiem)
      start_hour = start_value.to_s[/\d{1,2}/]&.to_i
      end_hour = end_value.to_s[/\d{1,2}/]&.to_i
      return nil unless start_hour&.between?(1, 12)

      return 'PM' if start_hour == 12
      return 'AM' if end_meridiem == 'PM' && end_hour && start_hour >= end_hour
      return 'PM' if end_meridiem == 'PM'
      return 'AM' if start_hour.between?(5, 11)

      end_meridiem
    end

    def inferred_end_meridiem(start_value, end_value)
      start_hour = start_value.to_s[/\d{1,2}/]&.to_i
      end_hour = end_value.to_s[/\d{1,2}/]&.to_i
      return nil unless start_hour&.between?(1, 12) && end_hour&.between?(1, 12)

      return 'PM' if end_hour == 12
      return 'PM' if start_hour >= 5

      nil
    end

    def point(address)
      return nil unless mappable_location?(address)

      resolver = @opts[:location_resolver] || (@location_resolver ||= Cambridge::LocationResolver.new)
      resolver.respond_to?(:call) ? resolver.call(address) : nil
    end

    def mappable_location?(address)
      return false if address.nil? || address.length > 120
      return false if address.match?(VAGUE_LOCATION)

      true
    end

    def dataset_url
      "#{SharedSoda::BASE_URL}/d/#{RESOURCE}"
    end
  end
end
