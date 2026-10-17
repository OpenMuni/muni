require_relative '_shared'
require_relative 'location_resolver'
require 'digest'

module Cambridge
  class DispatchCalls < Muni::Source
    include Cambridge::SharedSoda

    source :dispatch_calls,
           hall:     'cambridge',
           emits:    Muni::Records::DispatchCall,
           base_url: SharedSoda::BASE_URL,
           auth:     :app_token

    RESOURCE = ENV.fetch('CAMBRIDGE_DISPATCH_CALLS_RESOURCE', 'ppai-cur6').freeze

    def pull(since: nil, limit: 1_000)
      cursor = bounded_since(since, days: 30)
      where = "datetimereceived >= '#{soql_since(cursor)}'"
      rows = socrata.query(resource: RESOURCE, where: where, order: 'datetimereceived DESC', limit: limit)
      rows.map { |r| normalize(r) }
    end

    def cursor_time(record)
      record.received_at
    end

    private

    def normalize(row)
      emit(
        external_id:          external_id(row),
        hall:                 'cambridge',
        agency:               agency(row['primaryagency']),
        incident_type:        clean_string(row['type']),
        incident_group:       clean_string(row['group'] || row['fygroup']),
        priority:             clean_string(row['priority']),
        address:              clean_string(row['address']),
        intersection:         clean_string(row['intersection']),
        reporting_area:       clean_string(row['reportingarea']),
        firebox:              clean_string(row['firebox']),
        police_sector:        clean_string(row['policesector']),
        police_route:         clean_string(row['policeroute']),
        ladder_district:      clean_string(row['ladderdistrict']),
        engine_district:      clean_string(row['enginedistrict']),
        neighborhood:         clean_string(row['neighborhood']),
        location_description: location_description(row),
        location:             point(row),
        received_at:          Muni::Helpers::Normalize.parse_time(row['datetimereceived']),
        closed_at:            Muni::Helpers::Normalize.parse_time(row['datetimeclosed']),
        source_url:           dataset_url
      )
    end

    def agency(value)
      case clean_string(value).to_s.upcase
      when 'F' then 'Fire'
      when 'P' then 'Police'
      else clean_string(value)
      end
    end

    def external_id(row)
      fields = row.values_at('datetimereceived', 'datetimeclosed', 'primaryagency', 'type', 'address',
                             'intersection', 'reportingarea')
      "dispatch/#{Digest::SHA256.hexdigest(fields.join('|'))[0, 20]}"
    end

    def location_description(row)
      clean_string(row['location_1']) || clean_string(row['address']) || clean_string(row['intersection'])
    end

    def point(row)
      label = location_description(row)
      return nil unless label

      resolver = @opts[:location_resolver] || (@location_resolver ||= Cambridge::LocationResolver.new)
      resolver.respond_to?(:call) ? resolver.call(label) : nil
    end

    def dataset_url
      "#{SharedSoda::BASE_URL}/d/#{RESOURCE}"
    end
  end
end
