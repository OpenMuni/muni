require_relative '_shared'

module Cambridge
  # Current-edition development log: a small, curated snapshot of large-scale
  # projects. There is no per-record timestamp, so this is collected in full.
  class DevelopmentLog < Muni::Source
    include Cambridge::SharedSoda

    source :development_log,
           hall:     'cambridge',
           emits:    Muni::Records::DevelopmentProject,
           base_url: SharedSoda::BASE_URL,
           auth:     :app_token

    RESOURCE = ENV.fetch('CAMBRIDGE_DEVELOPMENT_LOG_RESOURCE', 'wjwg-93qh').freeze

    def pull(since: nil, limit: 500) # rubocop:disable Lint/UnusedMethodArgument
      rows = socrata.query(resource: RESOURCE, order: 'project_id', limit: limit)
      rows.map { |r| normalize(r) }
    end

    private

    def normalize(row)
      emit(
        external_id:       row['project_id'].to_s,
        hall:              'cambridge',
        name:              clean_string(row['project_name']),
        status:            clean_string(row['status']),
        address:           clean_string(row['address'] || row['geocode_address']),
        location:          point(row),
        primary_use:       clean_string(row['primary_use']),
        project_type:      clean_string(row['project_type']),
        residential_units: row['residential_units']&.to_i,
        affordable_units:  row['affordable_units']&.to_i,
        gross_floor_area:  money(row['total_gfa']),
        far:               row['far']&.to_f,
        developer:         clean_string(row['developer']),
        neighborhood:      clean_string(row['neighborhood']),
        zoning:            clean_string(row['zoning']),
        building_permit:   clean_string(row['building_permit']),
        year_complete:     row['year_complete']&.to_i,
        description:       clean_string(row['project_description']),
        source_url:        dataset_url
      )
    end

    def point(row)
      coords = row.dig('coordinates', 'coordinates')
      return Muni::Helpers::Geo.point(coords[0], coords[1]) if coords

      Muni::Helpers::Geo.point(row['longitude'], row['latitude'])
    end

    def dataset_url
      "#{SharedSoda::BASE_URL}/d/#{RESOURCE}"
    end
  end
end
