require_relative '_civic_page'

module Cambridge
  class CambridgeLife < Muni::Source
    include Cambridge::CivicPage

    source :cambridge_life,
           hall:     'cambridge',
           emits:    Muni::Records::DigestItem,
           base_url: CivicPage::CAMBRIDGE_BASE_URL

    def pull(since: nil, limit: 30)
      fetched_at = Time.now.utc
      publication_doc = html('/digital/publications')
      records = publication_records(publication_doc, fetched_at, since)
      records.concat(story_records(publication_doc, fetched_at, since, limit))
      unique_records(records, limit)
    end

    private

    def publication_records(doc, fetched_at, since)
      publication_nodes(doc).filter_map do |node|
        title = title_from(node)
        next unless title&.match?(/Cambridge Life|CityView/i)

        text = node_text(node)
        published_at = season_time(text)
        next if since && published_at && published_at < since

        digest_item(
          source_name:  'Cambridge Life',
          source_type:  'official_record',
          item_type:    'civic_life_story',
          section_hint: 'around_town',
          title:        title,
          summary:      truncate_text(summary_from(node, title: title), 420),
          category:     category_for(text),
          url:          href_from(node) || '/digital/publications',
          published_at: published_at,
          fetched_at:   fetched_at,
          tags:         ['cambridge life', category_for(text)],
          confidence:   0.86
        )
      end
    end

    def story_records(doc, fetched_at, since, limit)
      links = doc.css('a[href]').select { |link| node_text(link).to_s.match?(/view stories/i) }
      links.first(2).flat_map do |link|
        story_doc = html(URI(link['href']).path)
        story_nodes(story_doc).filter_map do |node|
          title = title_from(node)
          next unless title && !title.match?(/Cambridge Life|Spring|Winter|Fall|Summer/i)

          text = node_text(node)
          published_at = season_time(node_text(story_doc.at_css('h1, title')) || text)
          next if since && published_at && published_at < since

          digest_item(
            source_name:  'Cambridge Life',
            source_type:  'official_record',
            item_type:    'civic_life_story',
            section_hint: 'around_town',
            title:        title,
            summary:      truncate_text(summary_from(node, title: title), 420),
            category:     category_for(text),
            url:          href_from(node) || link['href'],
            published_at: published_at,
            fetched_at:   fetched_at,
            tags:         ['cambridge life', category_for(text)],
            confidence:   0.84
          )
        end
      rescue Muni::Helpers::Http::Error
        []
      end.first(limit.to_i)
    end

    def publication_nodes(doc)
      selectors = ['.publication', '.card', '.content-listing li', 'main article', 'main li']
      selectors.flat_map { |selector| doc.css(selector).to_a }
               .uniq
               .select { |node| node_text(node).to_s.match?(/Cambridge Life|CityView|Newsletter/i) }
    end

    def story_nodes(doc)
      selectors = ['main article', '.story-card', '.content-listing li', 'main li']
      selectors.flat_map { |selector| doc.css(selector).to_a }
               .uniq
               .select { |node| title_from(node) && node_text(node).to_s.length > 30 }
    end

    def season_time(text)
      raw = clean_text(text)
      match = raw&.match(/\b(20\d{2})\b/)
      year = match&.[](1)&.to_i
      return nil unless year

      month = case raw
              when /winter/i then 1
              when /spring/i then 4
              when /summer/i then 7
              when /fall|autumn/i then 10
              else 1
              end
      Time.utc(year, month, 1)
    end
  end
end
