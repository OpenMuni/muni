require_relative '_civic_page'

module Cambridge
  class CityConstructionProjects < Muni::Source
    include Cambridge::CivicPage

    PROJECTS_PATH = '/Departments/publicworks/cityprojects'.freeze
    MAP_PATH = '/departments/publicworks/cityprojects/map'.freeze

    source :city_construction_projects,
           hall:     'cambridge',
           emits:    Muni::Records::DigestItem,
           base_url: CivicPage::CAMBRIDGE_BASE_URL

    def pull(since: nil, limit: 40)
      fetched_at = Time.now.utc
      doc = html(PROJECTS_PATH)
      records = project_nodes(doc).filter_map do |node|
        title = title_from(node)
        text = node_text(node)
        next unless title && text.to_s.match?(/project|construction|streets?|sidewalk|sewer|utility|park/i)

        updated_at = local_date_time(first_date_text(text))
        next if since && updated_at && updated_at < since

        digest_item(
          source_name:   'City Construction Projects',
          source_type:   'official_record',
          item_type:     'construction_project',
          section_hint:  'street_level_impacts',
          title:         title,
          summary:       truncate_text(summary_from(node, title: title), 420),
          category:      'construction',
          url:           href_from(node) || PROJECTS_PATH,
          published_at:  updated_at,
          updated_at:    updated_at,
          fetched_at:    fetched_at,
          location_name: location_from_text(text),
          tags:          %w[construction project],
          confidence:    0.88
        )
      end

      records << map_context_record(fetched_at) if records.empty?
      unique_records(records, limit)
    end

    private

    def project_nodes(doc)
      selectors = ['main article', '.project', '.city-project', '.content-listing li', 'main li']
      selectors.flat_map { |selector| doc.css(selector).to_a }
               .uniq
               .select { |node| node_text(node).to_s.length > 30 }
    end

    def map_context_record(fetched_at)
      digest_item(
        external_id:  "#{self.class.slug}/construction-map",
        source_name:  'City Construction Projects',
        source_type:  'official_record',
        item_type:    'construction_project',
        section_hint: 'street_level_impacts',
        title:        'City construction map',
        summary:      'City map of active construction projects, street work, and related public works updates.',
        category:     'construction',
        url:          MAP_PATH,
        fetched_at:   fetched_at,
        tags:         %w[construction map],
        confidence:   0.82
      )
    rescue Muni::Helpers::Http::Error
      nil
    end

    def location_from_text(text)
      clean_text(text)&.match(/\b([^.;]+(?:Street|St\.|Avenue|Ave\.|Road|Rd\.|Square|Parkway|Way|Place))\b/i)&.[](1)
    end
  end
end
