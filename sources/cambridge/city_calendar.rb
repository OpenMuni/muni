require_relative '_official_events'

module Cambridge
  class CityCalendar < Muni::Source
    include Cambridge::CivicPage
    include Cambridge::OfficialEvents

    source :city_calendar,
           hall:     'cambridge',
           emits:    Muni::Records::DigestItem,
           base_url: CivicPage::CAMBRIDGE_BASE_URL

    def pull(since: nil, limit: 60)
      fetched_at = Time.now.utc
      records = parse_icalendar_events(calendar_body).filter_map do |event|
        normalize_calendar_event(event, fetched_at: fetched_at, since: since)
      end

      unique_records(records, limit)
    end

    private

    def allow_future_dates?
      true
    end

    def calendar_body
      http.get_raw('/citycalendar.ics', {}, headers: { 'Accept' => 'text/calendar,*/*;q=0.8' })
    end

    def normalize_calendar_event(event, fetched_at:, since:) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      title = clean_text(event[:title])
      start_at = event[:starts_at]
      return nil unless title
      return nil if since && start_at && start_at < since

      location = event_location(event[:location])
      end_at = event[:ends_at] || (event[:all_day] && start_at ? start_at + 86_400 : nil)
      meeting = meeting_title?(title)
      category = if meeting
                   'public meetings'
                 else
                   category_for([title, event[:summary], event[:categories]].join(' '), 'events')
                 end

      digest_item(
        external_id:    stable_id(self.class.slug, event[:uid] || event[:url], title, start_at, location),
        source_name:    'City Calendar',
        source_type:    'event_listing',
        item_type:      meeting ? 'public_meeting' : 'event',
        section_hint:   meeting ? 'civic_decisions' : event_calendar_section(start_at),
        title:          title,
        summary:        event_summary(event[:summary]),
        category:       category,
        url:            event[:url] || '/citycalendar',
        event_start_at: start_at,
        event_end_at:   end_at,
        published_at:   start_at || event[:updated_at],
        updated_at:     event[:updated_at],
        fetched_at:     fetched_at,
        location_name:  location,
        tags:           event_tags('calendar', category, event[:categories]),
        confidence:     0.95,
        dedupe_key:     meeting ? nil : official_event_dedupe_key(title, start_at, location),
        metadata:       {
          uid:        event[:uid],
          all_day:    event[:all_day],
          categories: event[:categories]
        }
      )
    end
  end
end
