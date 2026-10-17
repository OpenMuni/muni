require_relative '_shared'

module Cambridge
  class TreeInventory < Muni::Source
    include Cambridge::SharedSoda

    source :tree_inventory,
           hall:     'cambridge',
           emits:    Muni::Records::Tree,
           base_url: SharedSoda::BASE_URL,
           auth:     :app_token

    RESOURCE = ENV.fetch('CAMBRIDGE_TREES_RESOURCE', '82zb-7qc9').freeze

    def pull(since: nil, limit: 100, offset: 0) # rubocop:disable Lint/UnusedMethodArgument
      rows = socrata.query(resource: RESOURCE, order: 'treeid ASC', limit: limit, offset: offset)
      rows.map { |r| normalize(r) }
    end

    private

    def normalize(row)
      geom = row['the_geom'] || {}
      coords = geom['coordinates']
      emit(
        external_id:        (row['treeid'] || row['tree_id'] || row['_id']).to_s,
        hall:               'cambridge',
        species_common:     species_common(row),
        species_scientific: species_scientific(row),
        diameter_in:        row['diameter']&.to_f,
        condition:          condition(row),
        ownership:          clean_string(row['ownership']),
        plant_date:         Muni::Helpers::Normalize.parse_time(row['plantdate']),
        removal_date:       Muni::Helpers::Normalize.parse_time(row['removaldat']),
        order_number:       clean_string(row['order_']),
        notes:              clean_string(row['notes']),
        location:           coords ? Muni::Helpers::Geo.point(coords[0], coords[1]) : nil,
        source_url:         dataset_url
      )
    end

    def species_common(row)
      clean_string(row['commonname'] || row['common_name'] || row['species'] || row['sitetype'])
    end

    def species_scientific(row)
      clean_string(row['scientific'] || row['scientific_name'] || row['genus'])
    end

    def condition(row)
      site_type = clean_string(row['sitetype'] || row['tree_condition'])
      return site_type if site_type
      return 'Tree' if current_tree_without_site_type?(row)

      'Unclassified site'
    end

    def current_tree_without_site_type?(row)
      species_common(row) && Muni::Helpers::Normalize.parse_time(row['removaldat']).nil?
    end

    def dataset_url
      "#{SharedSoda::BASE_URL}/Public-Works/Street-Trees/#{RESOURCE}"
    end
  end
end
