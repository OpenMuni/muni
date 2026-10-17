require 'cgi'
require 'date'
require 'digest'
require 'nokogiri'
require 'rss'
require 'time'
require 'uri'
require_relative '_shared'

module Cambridge
  module CivicPage
    CAMBRIDGE_BASE_URL = 'https://www.cambridgema.gov'.freeze
    CAMBRIDGE_DAY_BASE_URL = 'https://www.cambridgeday.com'.freeze
    CITY_TIMEZONE = '-04:00'.freeze
    STOP_TITLES = /\A(?:home|search|view stories|download pdf|load more items|subscribe|donate|menu|close)\z/i

    def html(path, params = {})
      Nokogiri::HTML(http.get_raw(path, params))
    end

    def rss(path)
      RSS::Parser.parse(http.get_raw(path), false)
    end

    def digest_item(**attrs) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      now = Time.now.utc
      title = clean_text(attrs[:title])
      url = absolute_url(attrs[:url] || attrs[:source_url])
      source_slug = self.class.slug
      external_id = attrs[:external_id] || stable_id(source_slug, url, title, attrs[:published_at],
                                                     attrs[:event_start_at], attrs[:location_name])
      published_at = time_value(attrs[:published_at])
      event_start_at = time_value(attrs[:event_start_at])
      updated_at = time_value(attrs[:updated_at])
      fetched_at = time_value(attrs[:fetched_at]) || now

      emit(
        external_id:     external_id,
        hall:            'cambridge',
        source_slug:     source_slug,
        source_name:     attrs[:source_name] || source_label(source_slug),
        source_type:     attrs[:source_type] || 'official_record',
        item_type:       attrs[:item_type] || 'notice',
        section_hint:    attrs[:section_hint] || section_hint(attrs),
        title:           title,
        summary:         clean_text(attrs[:summary]),
        category:        clean_text(attrs[:category]),
        url:             url,
        published_at:    published_at,
        event_start_at:  event_start_at,
        event_end_at:    time_value(attrs[:event_end_at]),
        updated_at:      updated_at,
        fetched_at:      fetched_at,
        first_seen_at:   time_value(attrs[:first_seen_at]) || fetched_at,
        last_seen_at:    time_value(attrs[:last_seen_at]) || fetched_at,
        last_digest_at:  time_value(attrs[:last_digest_at]),
        location_name:   clean_text(attrs[:location_name]),
        neighborhood:    clean_text(attrs[:neighborhood]),
        location:        attrs[:location],
        tags:            Array(attrs[:tags]).map { |tag| clean_text(tag).to_s.downcase }.reject(&:empty?).uniq,
        confidence:      numeric(attrs[:confidence]) || default_confidence(attrs[:source_type]),
        freshness_score: numeric(attrs[:freshness_score]),
        dedupe_key:      attrs[:dedupe_key] || dedupe_key(source_slug, url, title, published_at, event_start_at),
        metadata:        stringify_json_keys(attrs[:metadata] || {}),
        collected_at:    fetched_at
      )
    end

    def source_label(slug)
      slug.to_s.split('/').last.tr('_', ' ').split.map(&:capitalize).join(' ')
    end

    def stable_id(*parts)
      key = parts.flatten.compact.join('|')
      "#{self.class.slug}/#{Digest::SHA256.hexdigest(key)[0, 24]}"
    end

    def dedupe_key(source_slug, url, title, published_at, event_start_at)
      normalized_url = url.to_s.sub(/\?.*\z/, '').sub(%r{/\z}, '')
      base = normalized_url.empty? ? [title, published_at || event_start_at].compact.join('|') : normalized_url
      "#{source_slug}:#{Digest::SHA256.hexdigest(base.to_s.downcase)[0, 24]}"
    end

    def absolute_url(value)
      raw = clean_text(value)
      return nil unless raw
      return raw if raw.start_with?('http://', 'https://')

      base = self.class.base_url || CAMBRIDGE_BASE_URL
      URI.join(base.end_with?('/') ? base : "#{base}/", raw).to_s
    rescue URI::InvalidURIError
      nil
    end

    def clean_text(value)
      raw = value.to_s
      raw = Nokogiri::HTML.fragment(raw).text if raw.include?('<')
      text = CGI.unescapeHTML(raw)
                .tr("\u00A0", ' ')
                .gsub(/\s+/, ' ')
                .strip
      text.empty? ? nil : text
    end

    def node_text(node)
      clean_text(node&.text)
    end

    def title_from(node)
      title_node = node&.name == 'a' ? node : node.at_css('h1 a, h2 a, h3 a, h4 a, h1, h2, h3, h4, a')
      title = node_text(title_node)
      return nil if title.nil? || title.match?(STOP_TITLES)

      title
    end

    def href_from(node)
      return absolute_url(node['href']) if node&.name == 'a' && node['href']

      link = node.at_css('h1 a[href], h2 a[href], h3 a[href], h4 a[href], a[href]')
      absolute_url(link&.[]('href'))
    end

    def summary_from(node, title: nil)
      paragraph = node.css('p').map { |p| node_text(p) }.find { |text| useful_summary?(text, title) }
      return paragraph if paragraph

      text = node_text(node)
      return nil unless text

      cleaned = title ? text.sub(title, '') : text
      cleaned = cleaned.gsub(date_pattern, '').gsub(time_pattern, '')
      clean_text(cleaned)
    end

    def useful_summary?(text, title)
      return false if text.nil? || text == title
      return false if text.match?(STOP_TITLES)

      text.length >= 20
    end

    def truncate_text(value, max)
      text = clean_text(value)
      return nil unless text
      return text if text.length <= max

      trimmed = text[0, max - 3].sub(/\s+\S*\z/, '').strip
      "#{trimmed.empty? ? text[0, max - 3] : trimmed}..."
    end

    def allow_future_dates?
      false
    end

    def local_date_time(date_text, time_text = nil, allow_future: allow_future_dates?)
      date = parse_date(date_text, allow_future: allow_future)
      return nil unless date

      hour, minute = parse_clock(time_text)
      Time.new(date.year, date.month, date.day, hour || 0, minute || 0, 0, CITY_TIMEZONE).utc
    rescue ArgumentError
      nil
    end

    def parse_date(text, allow_future: allow_future_dates?)
      raw = clean_text(text)
      return nil unless raw

      if (match = raw.match(%r{\b(\d{1,2})/(\d{1,2})(?:/(\d{4}))?\b}))
        year = (match[3] || Time.now.year).to_i
        return normalize_civic_date(
          Date.new(year, match[1].to_i, match[2].to_i),
          explicit_year: !match[3].nil?,
          allow_future:  allow_future
        )
      end

      if (match = raw.match(/\b([A-Z][a-z]+)\s+(\d{1,2})(?:,\s*(\d{4}))?\b/))
        year = (match[3] || Time.now.year).to_i
        return normalize_civic_date(
          Date.parse("#{match[1]} #{match[2]}, #{year}"),
          explicit_year: !match[3].nil?,
          allow_future:  allow_future
        )
      end

      parsed = Muni::Helpers::Normalize.parse_time(raw)
      normalize_civic_date(parsed&.to_date, explicit_year: true, allow_future: allow_future)
    rescue ArgumentError
      nil
    end

    def normalize_civic_date(date, explicit_year:, allow_future:)
      return nil unless date
      return date if allow_future
      return date if date <= Date.today
      return nil if explicit_year

      previous_year = Date.new(date.year - 1, date.month, date.day)
      previous_year <= Date.today ? previous_year : nil
    rescue ArgumentError
      nil
    end

    def parse_clock(text)
      raw = clean_text(text)
      return [nil, nil] unless raw

      match = raw.match(/\b(\d{1,2})(?::(\d{2}))?\s*([ap]\.?m\.?)?\b/i)
      return [nil, nil] unless match

      hour = match[1].to_i
      minute = (match[2] || '0').to_i
      meridiem = match[3]&.downcase
      if meridiem&.start_with?('p') && hour < 12
        hour += 12
      elsif meridiem&.start_with?('a') && hour == 12
        hour = 0
      end
      [hour, minute]
    end

    def time_value(value)
      return nil if value.nil?
      return value.utc if value.respond_to?(:utc)

      Muni::Helpers::Normalize.parse_time(value)
    end

    def numeric(value)
      number = Float(value)
      number.finite? ? number : nil
    rescue ArgumentError, TypeError
      nil
    end

    def stringify_json_keys(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested), hash|
          hash[key.to_s] = stringify_json_keys(nested)
        end
      when Array
        value.map { |nested| stringify_json_keys(nested) }
      else
        value
      end
    end

    def default_confidence(source_type)
      source_type.to_s == 'press_report' ? 0.72 : 0.9
    end

    def category_for(text, fallback = nil)
      haystack = text.to_s.downcase
      return 'construction' if haystack.match?(/construction|street closure|road|utility|detour|sidewalk/)
      return 'public meetings' if haystack.match?(/council|committee|board|commission|agenda|public comment/)
      return 'services' if haystack.match?(/trash|recycling|compost|street cleaning|collection|reminder|alert/)
      return 'events' if haystack.match?(/class|program|workshop|library|senior|community|event/)
      return 'housing' if haystack.match?(/housing|affordable|renter|homeowner/)
      return 'environment' if haystack.match?(/tree|park|open space|drought|climate|sustainability/)

      fallback || 'civic update'
    end

    def section_hint(attrs)
      text = [attrs[:title], attrs[:summary], attrs[:category], attrs[:item_type],
              attrs[:tags]].flatten.compact.join(' ')
      category = category_for(text)
      return 'street_level_impacts' if category == 'construction'
      return 'civic_decisions' if category == 'public meetings'
      return 'practical_reminders' if category == 'services'
      return 'around_town' if attrs[:source_type].to_s == 'press_report'
      return 'around_town' if category == 'events'

      'today_in_cambridge'
    end

    def date_pattern
      %r{\b(?:\d{1,2}/\d{1,2}/\d{4}|[A-Z][a-z]+\s+\d{1,2}(?:,\s*\d{4})?)\b}
    end

    def time_pattern
      /\b\d{1,2}(?::\d{2})?\s*(?:a\.?m\.?|p\.?m\.?|AM|PM)\b/
    end

    def first_date_text(text)
      clean_text(text)&.match(date_pattern)&.[](0)
    end

    def first_time_text(text)
      clean_text(text)&.match(time_pattern)&.[](0)
    end

    def unique_records(records, limit)
      seen = {}
      records.filter_map do |record|
        next unless record&.title

        key = record.dedupe_key || record.external_id
        next if seen[key]

        seen[key] = true
        record
      end.first(limit.to_i.positive? ? limit.to_i : records.length)
    end
  end
end
