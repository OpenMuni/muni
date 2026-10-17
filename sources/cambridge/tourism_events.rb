require_relative '_official_events'

module Cambridge
  class TourismEvents < Muni::Source
    include Cambridge::CivicPage
    include Cambridge::OfficialEvents

    API_PATH = '/wp-json/tribe/events/v1/events'.freeze
    WINDOW_DAYS = 60
    MAX_PAGE_SIZE = 100

    source :tourism_events,
           hall:     'cambridge',
           emits:    Muni::Records::DigestItem,
           base_url: 'https://cambridgeusa.org'

    def pull(since: nil, limit: 200)
      fetched_at = Time.now.utc
      records = fetch_rows(limit).filter_map do |row|
        normalize_tourism_event(row, fetched_at: fetched_at, since: since)
      end

      unique_records(records, limit)
    end

    private

    def allow_future_dates?
      true
    end

    def fetch_rows(limit)
      page = 1
      rows = []
      loop do
        data = http.get(API_PATH, request_params(page, limit))
        rows.concat(Array(data['events']))
        total_pages = data['total_pages'].to_i
        break if rows.length >= limit.to_i
        break if total_pages.positive? && page >= total_pages
        break if Array(data['events']).empty?

        page += 1
      end
      rows
    end

    def request_params(page, limit)
      today = Muni::LocalTime.local_time(Time.now.utc, city: 'cambridge').to_date
      {
        page:       page,
        per_page:   limit.to_i.clamp(1, MAX_PAGE_SIZE),
        start_date: "#{today.strftime('%Y-%m-%d')} 00:00:00",
        end_date:   "#{(today + WINDOW_DAYS).strftime('%Y-%m-%d')} 23:59:59",
        status:     'publish'
      }
    end

    def normalize_tourism_event(row, fetched_at:, since:)
      title = clean_text(wp_text(row['title']))
      start_at = tourism_event_time(row, 'start')
      end_at = tourism_event_time(row, 'end')
      return nil unless title && start_at
      return nil if since && start_at < since

      context = tourism_event_context(row, title)
      return nil unless context

      external_key = row['global_id'] || row['id'] || context[:source_url]
      digest_item(
        external_id:    stable_id(self.class.slug, external_key, title, start_at),
        source_name:    'Cambridge Office for Tourism',
        source_type:    'event_listing',
        item_type:      'event',
        section_hint:   event_calendar_section(start_at),
        title:          title,
        summary:        event_summary(row['description']),
        category:       context[:category],
        url:            context[:source_url],
        event_start_at: start_at,
        event_end_at:   end_at,
        published_at:   start_at,
        updated_at:     parse_utc_time(row['modified_utc']),
        fetched_at:     fetched_at,
        location_name:  context[:location_name],
        location:       context[:point],
        tags:           event_tags('tourism', context[:categories], term_names(row['tags'])),
        confidence:     0.9,
        dedupe_key:     official_event_dedupe_key(title, start_at, context[:location_name]),
        metadata:       tourism_metadata(row, context[:venue], context[:categories])
      )
    end

    def tourism_event_context(row, title)
      venue = row['venue'].is_a?(Hash) ? row['venue'] : {}
      location_name = event_location(venue['venue'] || venue_address(venue))
      point = cambridge_venue?(venue) ? nil : resolve_event_location(venue_address(venue) || location_name)
      return nil unless cambridge_venue?(venue, point: point)

      categories = term_names(row['categories'])
      category = clean_text(categories.first)&.downcase
      {
        venue:         venue,
        location_name: location_name,
        point:         point,
        categories:    categories,
        source_url:    clean_text(row['url'] || row['website'] || row['rest_url']),
        category:      category || category_for([title, row['description']].join(' '), 'events')
      }
    end

    def wp_text(value)
      value.is_a?(Hash) ? value['rendered'] || value['raw'] : value
    end

    def venue_address(venue)
      event_location(
        [venue['address'], venue['city'], venue['state'] || venue['province'], venue['zip']].compact.join(', ')
      )
    end

    def term_names(rows)
      Array(rows).filter_map do |row|
        clean_text(row.is_a?(Hash) ? row['name'] || row['slug'] : row)
      end
    end

    def tourism_metadata(row, venue, categories)
      {
        global_id:  row['global_id'],
        rest_url:   row['rest_url'],
        website:    clean_text(row['website']),
        cost:       clean_text(row['cost']),
        image_url:  row.dig('image', 'url'),
        all_day:    row['all_day'] ? true : false,
        timezone:   clean_text(row['timezone'] || row['timezone_abbr']),
        venue:      venue,
        categories: categories,
        tags:       term_names(row['tags'])
      }
    end

    def resolve_event_location(label)
      resolver = @opts[:location_resolver] || (@location_resolver ||= Cambridge::LocationResolver.new)
      resolver.respond_to?(:call) ? resolver.call(label) : nil
    rescue StandardError
      nil
    end
  end
end
