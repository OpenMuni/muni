require_relative '_civic_page'

module Cambridge
  class CityNews < Muni::Source
    include Cambridge::CivicPage

    source :city_news,
           hall:     'cambridge',
           emits:    Muni::Records::DigestItem,
           base_url: CivicPage::CAMBRIDGE_BASE_URL

    def pull(since: nil, limit: 25)
      fetched_at = Time.now.utc
      records = news_nodes(html('/news')).filter_map do |node|
        title = title_from(node)
        next unless title

        text = node_text(node)
        published_at = local_date_time(first_date_text(text))
        next if since && published_at && published_at < since

        digest_item(
          source_name:  'Official City News',
          source_type:  'official_record',
          item_type:    'announcement',
          title:        title,
          summary:      truncate_text(summary_from(node, title: title), 420),
          category:     category_for(text),
          url:          href_from(node) || '/news',
          published_at: published_at,
          updated_at:   published_at,
          fetched_at:   fetched_at,
          tags:         tags_for(text),
          confidence:   0.94
        )
      end

      unique_records(records, limit)
    end

    private

    def news_nodes(doc)
      selectors = [
        '.news-listing li',
        '.search-results li',
        '.content-listing li',
        'main article',
        'main li'
      ]
      nodes = selectors.flat_map { |selector| doc.css(selector).to_a }
      nodes = doc.css('a[href]').map(&:parent) if nodes.empty?
      nodes.uniq.select { |node| title_from(node) && node_text(node).to_s.length > 30 }
    end

    def tags_for(text)
      category = category_for(text)
      [category, *text.to_s.scan(/Drought|Housing|Street Cleaning|Public Works|Library|Traffic|Commission/i)].uniq
    end
  end
end
