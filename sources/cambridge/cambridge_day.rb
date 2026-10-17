require_relative '_civic_page'

module Cambridge
  class CambridgeDay < Muni::Source
    include Cambridge::CivicPage

    source :cambridge_day,
           hall:     'cambridge',
           emits:    Muni::Records::DigestItem,
           base_url: CivicPage::CAMBRIDGE_DAY_BASE_URL

    def pull(since: nil, limit: 20)
      fetched_at = Time.now.utc
      records = rss_records(fetched_at, since)
      records = homepage_records(fetched_at, since) if records.empty?
      unique_records(records, limit)
    end

    private

    def rss_records(fetched_at, since)
      feed = rss('/feed/')
      Array(feed&.items).filter_map do |item|
        published_at = time_value(item.respond_to?(:pubDate) ? item.pubDate : item.date)
        next if since && published_at && published_at < since

        digest_item(
          source_name:  'Cambridge Day',
          source_type:  'press_report',
          item_type:    'press_headline',
          section_hint: 'around_town',
          title:        item.title,
          summary:      truncate_text(item.description, 280),
          category:     category_for([item.title, item.description, item.category&.content].compact.join(' ')),
          url:          item.link,
          published_at: published_at,
          fetched_at:   fetched_at,
          tags:         ['press', item.category&.content].compact,
          confidence:   0.7,
          metadata:     { copyright_scope: 'headline_excerpt_only' }
        )
      end
    rescue StandardError => e
      Muni::Logger.instance.warn("Cambridge Day RSS fallback: #{e.class}: #{e.message}")
      []
    end

    def homepage_records(fetched_at, since)
      homepage_nodes(html('/')).filter_map do |node|
        title = title_from(node)
        next unless title

        text = node_text(node)
        published_at = local_date_time(first_date_text(text))
        next if since && published_at && published_at < since

        digest_item(
          source_name:  'Cambridge Day',
          source_type:  'press_report',
          item_type:    'press_headline',
          section_hint: 'around_town',
          title:        title,
          summary:      truncate_text(summary_from(node, title: title), 280),
          category:     category_for(text),
          url:          href_from(node),
          published_at: published_at,
          fetched_at:   fetched_at,
          tags:         ['press', category_for(text)],
          confidence:   0.68,
          metadata:     { copyright_scope: 'headline_excerpt_only' }
        )
      end
    end

    def homepage_nodes(doc)
      selectors = ['main article', 'article', '.post', '.entry', 'main li']
      selectors.flat_map { |selector| doc.css(selector).to_a }
               .uniq
               .select { |node| title_from(node) && href_from(node).to_s.start_with?(self.class.base_url) }
    end
  end
end
