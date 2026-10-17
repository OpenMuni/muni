require_relative '_civic_page'

module Cambridge
  class PracticalServices < Muni::Source
    include Cambridge::CivicPage

    STREET_CLEANING = '/services/streetcleaning'.freeze
    CURBSIDE = '/services/curbsidecollections'.freeze
    SUBSCRIBE = '/subscribe#AlertsReminders'.freeze

    source :practical_services,
           hall:     'cambridge',
           emits:    Muni::Records::DigestItem,
           base_url: CivicPage::CAMBRIDGE_BASE_URL

    def pull(since: nil, limit: 30)
      fetched_at = Time.now.utc
      records = []
      records.concat(street_cleaning_records(fetched_at, since))
      records.concat(curbside_records(fetched_at, since))
      records.concat(subscribe_records(fetched_at))
      unique_records(records, limit)
    end

    private

    def street_cleaning_records(fetched_at, since)
      doc = html(STREET_CLEANING)
      page_modified = page_modified_at(doc)
      holiday_nodes(doc).filter_map do |node|
        text = node_text(node)
        title = text&.split(':')&.first || 'Street cleaning update'
        effective_at = local_date_time(first_date_text(text))
        next if since && effective_at && effective_at < since

        digest_item(
          source_name:  'Street Cleaning',
          source_type:  'official_record',
          item_type:    'service_reminder',
          section_hint: 'practical_reminders',
          title:        title,
          summary:      truncate_text(text, 360),
          category:     'street cleaning',
          url:          STREET_CLEANING,
          published_at: effective_at || page_modified,
          updated_at:   page_modified,
          fetched_at:   fetched_at,
          tags:         ['street cleaning', 'reminder'],
          confidence:   0.88
        )
      end
    end

    def curbside_records(fetched_at, since)
      doc = html(CURBSIDE)
      page_modified = page_modified_at(doc)
      service_nodes(doc).filter_map do |node|
        text = node_text(node)
        next unless text&.match?(/holiday|collection|trash|recycling|compost|pickup|curbside/i)

        effective_at = local_date_time(first_date_text(text))
        next if since && effective_at && effective_at < since

        digest_item(
          source_name:  'Curbside Collections',
          source_type:  'official_record',
          item_type:    'service_reminder',
          section_hint: 'practical_reminders',
          title:        title_from(node) || inferred_title(text, 'Curbside collections'),
          summary:      truncate_text(text, 360),
          category:     'curbside collections',
          url:          CURBSIDE,
          published_at: effective_at || page_modified,
          updated_at:   page_modified,
          fetched_at:   fetched_at,
          tags:         %w[trash recycling compost reminder],
          confidence:   0.88
        )
      end
    end

    def subscribe_records(fetched_at)
      doc = html('/subscribe')
      nodes = doc.css('main a[href], body a[href]').select do |link|
        node_text(link).to_s.match?(/alert|reminder|street cleaning|recycling|trash|CSO/i)
      end
      nodes.map do |node|
        title = node_text(node)
        digest_item(
          source_name:  'City Subscribe',
          source_type:  'official_record',
          item_type:    'service_reminder',
          section_hint: 'practical_reminders',
          title:        title,
          summary:      "Subscribe for #{title.downcase}.",
          category:     'alerts and reminders',
          url:          node['href'] || SUBSCRIBE,
          fetched_at:   fetched_at,
          tags:         %w[alerts reminders],
          confidence:   0.76
        )
      end
    rescue Muni::Helpers::Http::Error
      []
    end

    def holiday_nodes(doc)
      doc.css('main li, main p').select { |node| node_text(node).to_s.match?(/rescheduled|holiday|street cleaning/i) }
    end

    def service_nodes(doc)
      doc.css('main li, main p').select { |node| node_text(node).to_s.length > 24 }
    end

    def page_modified_at(doc)
      text = node_text(doc.at_css('main, body'))
      match = text&.match(/Page was last modified on\s+([^.]+?)(?:\s{2,}|$)/i)
      local_date_time(match&.[](1))
    end

    def inferred_title(text, fallback)
      clean_text(text)&.split(/[.;:]/)&.first || fallback
    end
  end
end
