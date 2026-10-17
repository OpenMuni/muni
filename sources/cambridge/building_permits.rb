require_relative '_shared'

module Cambridge
  class BuildingPermits < Muni::Source
    include Cambridge::SharedSoda

    source :building_permits,
           hall:     'cambridge',
           emits:    Muni::Records::BuildingPermit,
           base_url: SharedSoda::BASE_URL,
           auth:     :app_token

    RESOURCE = ENV.fetch('CAMBRIDGE_PERMITS_RESOURCE', 'qu2z-8suj').freeze

    def pull(since: nil, limit: 500)
      cursor = bounded_since(since, days: 30)
      where = "issue_date >= '#{soql_since(cursor)}'"
      rows = socrata.query(resource: RESOURCE, where: where,
                           order: 'issue_date DESC', limit: limit)
      rows.map { |r| normalize(r) }
    end

    def cursor_time(record)
      record.issued_at || record.applied_at
    end

    private

    def normalize(row)
      emit(
        external_id:        (row['id'] || row['permit_number'] || row['_id']).to_s,
        hall:               'cambridge',
        permit_type:        clean_string(row['permit_type'] || row['current_property_use']),
        status:             clean_string(row['status']),
        description:        clean_string(row['detailed_description_of_work'] ||
                            row['isd_approved_description'] ||
                            row['description_of_work']),
        address:            clean_string(row['full_address'] || row['address']),
        location:           point(row),
        declared_valuation: row['total_cost']&.to_f || row['building_cost']&.to_f,
        applied_at:         Muni::Helpers::Normalize.parse_time(row['applicant_submit_date']),
        issued_at:          Muni::Helpers::Normalize.parse_time(row['issue_date'] || row['issued_date']),
        property_use:       clean_string(row['current_property_use']),
        proposed_use:       clean_string(row['proposed_property_use']),
        mbl:                clean_string(row['mbl']),
        source_url:         dataset_url
      )
    end

    def point(row)
      coords = row.dig('coordinates', 'coordinates')
      return Muni::Helpers::Geo.point(coords[0], coords[1]) if coords

      Muni::Helpers::Geo.point(row['longitude'], row['latitude'])
    end

    def dataset_url
      "#{SharedSoda::BASE_URL}/Inspectional-Services/Building-Permits-Addition-Alteration/#{RESOURCE}"
    end
  end
end
