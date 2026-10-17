require_relative '_civic_page'

module Cambridge
  class ConstructionHighlights < Muni::Source
    include Cambridge::CivicPage

    PATH = '/departments/publicworks/cityprojects/weeklyconstructionhighlights'.freeze

    source :construction_highlights,
           hall:     'cambridge',
           emits:    Muni::Records::DigestItem,
           base_url: CivicPage::CAMBRIDGE_BASE_URL

    def pull(since: nil, limit: 40)
      fetched_at = Time.now.utc
      records = impact_nodes(html(PATH)).filter_map do |node|
        text = node_text(node)
        title = title_from(node) || inferred_title(text)
        next unless title && construction_record?(node, title, text)

        published_at = local_date_time(first_date_text(text))
        next if since && published_at && published_at < since

        digest_item(
          source_name:   'Weekly Construction Highlights',
          source_type:   'official_record',
          item_type:     'construction_impact',
          section_hint:  'street_level_impacts',
          title:         title,
          summary:       truncate_text(construction_summary(node, title, text), 420),
          category:      'construction',
          url:           href_from(node) || PATH,
          published_at:  published_at,
          updated_at:    published_at,
          fetched_at:    fetched_at,
          location_name: location_from_text(text),
          tags:          ['construction', 'street impact'],
          confidence:    0.9
        )
      end

      unique_records(records, limit)
    end

    private

    def impact_nodes(doc)
      pdf_links = doc.css('main a[href]').select { |link| construction_minutes_link?(link) }
      selectors = ['main article', '.project', '.construction-highlight', '.content-listing li', 'main li', 'main p']
      page_nodes = selectors.flat_map { |selector| doc.css(selector).to_a }
                            .uniq
                            .select { |node| node_text(node).to_s.length > 30 }
      (pdf_links + page_nodes).uniq
    end

    def construction_record?(node, title, text)
      return false if generic_intro?(text)
      return true if construction_minutes_link?(node)
      return true if title.to_s.match?(/\AWeek of /i)

      text.to_s.match?(/construction|utility|street|sidewalk|road|closure|detour|project/i)
    end

    def generic_intro?(text)
      text.to_s.match?(/\Aconstruction meetings are held/i) ||
        text.to_s.match?(/\Afor updated information about city construction projects/i)
    end

    def construction_minutes_link?(node)
      node.name == 'a' &&
        node_text(node).to_s.match?(/\AWeek of /i) &&
        node['href'].to_s.match?(%r{constructionmeetingminutes/.+\.pdf\z}i)
    end

    def construction_summary(node, title, text)
      summary_from(node, title: title) || "Weekly construction highlights for #{title}." || text
    end

    def inferred_title(text)
      clean_text(text)&.split(/[.;:]/)&.first
    end

    def location_from_text(text)
      street_suffix = /Street|St\.|Avenue|Ave\.|Road|Rd\.|Square|Parkway|Way|Place/i
      clean_text(text)&.match(/\b(?:on|at|near)\s+([^.;]+(?:#{street_suffix}))\b/i)&.[](1)
    end
  end
end
