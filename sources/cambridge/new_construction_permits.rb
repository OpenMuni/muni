require_relative '_shared'

module Cambridge
  class NewConstructionPermits < Muni::Source
    include Cambridge::SharedSoda

    source :new_construction_permits,
           hall:     'cambridge',
           emits:    Muni::Records::NewConstructionPermit,
           base_url: SharedSoda::BASE_URL,
           auth:     :app_token

    RESOURCE = ENV.fetch('CAMBRIDGE_NEW_CONSTRUCTION_RESOURCE', '9qm7-wbdc').freeze

    def pull(since: nil, limit: 1_000) # rubocop:disable Lint/UnusedMethodArgument
      rows = socrata.query(resource: RESOURCE, order: 'issue_date DESC', limit: limit)
      rows.map { |r| normalize(r) }
    end

    def cursor_time(record)
      record.issued_at || record.applied_at
    end

    private

    def normalize(row)
      emit(
        external_id:          (row['id'] || row['viewpoint_id']).to_s,
        hall:                 'cambridge',
        status:               clean_string(row['status']),
        address:              clean_string(row['full_address']),
        location:             point(row),
        proposed_use:         clean_string(row['proposed_building_use'] || row['proposed_property_use']),
        construction_type:    clean_string(row['construction_type']),
        dwelling_units:       row['proposed_count_of_dwelling']&.to_i,
        gross_square_footage: money(row['gross_square_footage']),
        declared_valuation:   money(row['total_cost_of_construction'] || row['building_cost']),
        description:          clean_string(row['description_of_work'] || row['isd_approved_description']),
        mbl:                  clean_string(row['mbl']),
        applied_at:           Muni::Helpers::Normalize.parse_time(row['applicant_submit_date']),
        issued_at:            Muni::Helpers::Normalize.parse_time(row['issue_date']),
        source_url:           dataset_url
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
