require_relative '_shared'

module Cambridge
  class ZoningAppeals < Muni::Source
    include Cambridge::SharedSoda

    source :zoning_appeals,
           hall:     'cambridge',
           emits:    Muni::Records::ZoningAppeal,
           base_url: SharedSoda::BASE_URL,
           auth:     :app_token

    RESOURCE = ENV.fetch('CAMBRIDGE_ZONING_APPEALS_RESOURCE', 'urfm-usws').freeze

    def pull(since: nil, limit: 1_000) # rubocop:disable Lint/UnusedMethodArgument
      rows = socrata.query(resource: RESOURCE, order: 'applicant_submit_date DESC', limit: limit)
      rows.map { |r| normalize(r) }
    end

    def cursor_time(record)
      record.applied_at || record.decided_at
    end

    private

    def normalize(row)
      emit(
        external_id:              row['id'].to_s,
        hall:                     'cambridge',
        status:                   clean_string(row['status']),
        address:                  clean_string(row['full_address']),
        location:                 point(row),
        current_use:              clean_string(row['current_use']),
        proposed_use:             clean_string(row['proposed_use']),
        zoning_district:          clean_string(row['zoning_district']),
        relief:                   clean_string(row['variance_relief_description'] ||
                                  row['special_permit_relief_description'] ||
                                  row['summary_for_publication']),
        dwelling_units_requested: row['requested_no_of_dwelling_units']&.to_i,
        applied_at:               Muni::Helpers::Normalize.parse_time(row['applicant_submit_date']),
        hearing_deadline_at:      Muni::Helpers::Normalize.parse_time(row['variance_hearing_deadline'] ||
                                  row['special_permit_hearing_deadline']),
        decided_at:               Muni::Helpers::Normalize.parse_time(row['issue_date']),
        source_url:               dataset_url
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
