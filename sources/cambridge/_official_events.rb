require 'date'
require 'digest'
require 'time'
require_relative '_civic_page'
require_relative 'location_resolver'

module Cambridge
  module OfficialEvents
    MEETING_TITLE = /board|commission|committee|council|public meeting|hearing|agenda/i
    EXTERNAL_CITY = /\b(?:Boston|Somerville|Arlington|Belmont|Watertown|Medford|Brookline)\b/i

    class ICalendarParser
      def initialize(body, city: 'cambridge')
        @body = body.to_s
        @city = city
      end

      def events
        vevent_lines.map { |lines| event_from(lines) }
      end

      private

      attr_reader :body, :city

      def vevent_lines
        events = []
        current = nil
        unfolded_lines.each do |line|
          case line.upcase
          when 'BEGIN:VEVENT'
            current = []
          when 'END:VEVENT'
            events << current if current
            current = nil
          else
            current << line if current
          end
        end
        events
      end

      def unfolded_lines
        lines = body.gsub(/\r\n?/, "\n").split("\n")
        lines.each_with_object([]) do |line, out|
          if line.start_with?(' ', "\t") && out.any?
            out[-1] = "#{out[-1]}#{line[1..]}"
          else
            out << line
          end
        end
      end

      def event_from(lines)
        fields = Hash.new { |hash, key| hash[key] = [] }
        lines.each do |line|
          parsed = line_value(line)
          fields[parsed[:name]] << parsed if parsed
        end
        start = time_field(first(fields, 'DTSTART'))
        finish = time_field(first(fields, 'DTEND'))
        {
          uid:        value(first(fields, 'UID')),
          title:      value(first(fields, 'SUMMARY')),
          summary:    value(first(fields, 'DESCRIPTION')),
          location:   value(first(fields, 'LOCATION')),
          url:        value(first(fields, 'URL')),
          categories: categories_from(fields),
          starts_at:  start && start[:time],
          ends_at:    finish && finish[:time],
          all_day:    start && start[:all_day] ? true : false,
          updated_at: updated_time(fields)
        }
      end

      def categories_from(fields)
        fields['CATEGORIES'].flat_map { |field| value(field).to_s.split(',') }
                            .map(&:strip)
                            .reject(&:empty?)
      end

      def updated_time(fields)
        time_field(first(fields, 'LAST-MODIFIED'))&.fetch(:time, nil) ||
          time_field(first(fields, 'DTSTAMP'))&.fetch(:time, nil)
      end

      def line_value(line)
        head, raw_value = line.split(':', 2)
        return nil unless raw_value

        name, params = head.split(';').then { |parts| [parts.shift.to_s.upcase, parse_params(parts)] }
        { name: name, params: params, value: unescape(raw_value) }
      end

      def parse_params(parts)
        parts.each_with_object({}) do |part, params|
          key, value = part.split('=', 2)
          params[key.to_s.upcase] = value.to_s.split(',') if key
        end
      end

      def first(fields, name)
        fields[name].first
      end

      def value(field)
        field && field[:value]
      end

      def unescape(value)
        value.to_s
             .gsub(/\\[nN]/, "\n")
             .gsub('\\,', ',')
             .gsub('\\;', ';')
             .gsub('\\\\', '\\')
      end

      def time_field(field)
        return nil unless field

        value = field[:value].to_s
        all_day = field.dig(:params, 'VALUE')&.include?('DATE') || value.match?(/\A\d{8}\z/)
        return { time: parse_date(value), all_day: true } if all_day

        { time: parse_datetime(value, field[:params]), all_day: false }
      end

      def parse_date(value)
        date = Date.strptime(value, '%Y%m%d')
        Muni::LocalTime.local_to_utc(date.year, date.month, date.day, 0, 0, 0, city: city)
      rescue ArgumentError
        nil
      end

      def parse_datetime(value, params)
        if value.end_with?('Z')
          parse_utc(value.delete_suffix('Z'))
        elsif params['TZID']&.any? { |tz| tz.casecmp('utc').zero? }
          parse_utc(value)
        else
          parse_local(value)
        end
      end

      def parse_utc(value)
        parts = datetime_parts(value) or return nil
        Time.utc(*parts)
      end

      def parse_local(value)
        parts = datetime_parts(value) or return nil
        Muni::LocalTime.local_to_utc(*parts, city: city)
      end

      def datetime_parts(value)
        match = value.match(/\A(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(?:(\d{2}))?\z/)
        return nil unless match

        [match[1].to_i, match[2].to_i, match[3].to_i, match[4].to_i, match[5].to_i, (match[6] || '0').to_i]
      end
    end

    def parse_icalendar_events(body)
      ICalendarParser.new(body).events
    end

    def official_event_dedupe_key(title, start_at, location_name)
      local_time = start_at && Muni::LocalTime.local_time(start_at, city: 'cambridge').strftime('%Y%m%dT%H%M')
      key = [normalized_event_key(title), local_time, normalized_event_key(location_name)].compact.join('|')
      "event:#{Digest::SHA256.hexdigest(key)[0, 24]}"
    end

    def event_location(value)
      clean_text(value.to_s.gsub(%r{<br\s*/?>}i, ', '))
    end

    def event_summary(value, max: 500)
      truncate_text(value, max)
    end

    def event_tags(*values)
      values.flatten.compact.map { |value| clean_text(value).to_s.downcase }.reject(&:empty?).uniq
    end

    def meeting_title?(title)
      title.to_s.match?(MEETING_TITLE)
    end

    def event_calendar_section(event_start)
      return 'around_town' unless event_start

      local_event = Muni::LocalTime.local_time(event_start, city: 'cambridge').to_date
      local_today = Muni::LocalTime.local_time(Time.now.utc, city: 'cambridge').to_date
      local_event == local_today ? 'today_in_cambridge' : 'around_town'
    end

    def tourism_event_time(row, key)
      local_value = row["#{key}_date"]
      utc_value = row["utc_#{key}_date"]
      timezone = row['timezone'].to_s
      return parse_cambridge_local_time(local_value) if timezone.empty? || timezone == 'UTC+0'

      parse_utc_time(utc_value) || parse_cambridge_local_time(local_value)
    end

    def parse_cambridge_local_time(value)
      match = value.to_s.match(/\A(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?)?/)
      return nil unless match

      Muni::LocalTime.local_to_utc(
        match[1].to_i, match[2].to_i, match[3].to_i,
        (match[4] || '0').to_i, (match[5] || '0').to_i, (match[6] || '0').to_i,
        city: 'cambridge'
      )
    end

    def parse_utc_time(value)
      match = value.to_s.match(/\A(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?)?/)
      return nil unless match

      Time.utc(match[1].to_i, match[2].to_i, match[3].to_i,
               (match[4] || '0').to_i, (match[5] || '0').to_i, (match[6] || '0').to_i)
    end

    def cambridge_venue?(venue, point: nil)
      city = clean_text(venue['city']).to_s
      state = clean_text(venue['state'] || venue['province']).to_s
      address = [venue['address'], venue['venue'], city, state, venue['zip']].compact.join(', ')
      return false if address.match?(EXTERNAL_CITY) && !city.casecmp('Cambridge').zero?
      return true if city.casecmp('Cambridge').zero? && ['', 'ma', 'massachusetts'].include?(state.downcase)
      return true if address.match?(/\bCambridge,\s*(?:MA|Massachusetts)\b/i)
      return true if point_inside_cambridge?(point)

      false
    end

    def point_inside_cambridge?(point)
      return false unless point

      boundary = Muni::Hall.find('cambridge')&.boundary
      Muni::Helpers::Geo.boundary_contains?(boundary, point[0], point[1])
    end

    def normalized_event_key(value)
      clean_text(value).to_s.downcase.gsub(/[^a-z0-9]+/, ' ').strip
    end
  end
end
