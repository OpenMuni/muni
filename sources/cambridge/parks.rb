require_relative '_shared'
require 'muni/clients/arcgis'

module Cambridge
  class Parks < Muni::Source
    include Cambridge::SharedSoda

    source :parks,
           hall:     'cambridge',
           emits:    Muni::Records::Park,
           base_url: 'https://gis.cambridgema.gov'

    LAYER_PATH = '/arcgis/rest/services/CDDBasemap/MapServer/348/query'.freeze
    SOURCE_URL = 'https://gis.cambridgema.gov/arcgis/rest/services/CDDBasemap/MapServer/348'.freeze
    PARK_FCODES = {
      1  => 'City park',
      21 => 'DCR/state park',
      41 => 'Public open space',
      42 => 'Public open space',
      43 => 'Rooftop park'
    }.freeze
    WHERE = "FCODE IN (#{PARK_FCODES.keys.join(',')})".freeze
    OUT_FIELDS = %w[
      OBJECTID
      JOIN_ID
      FCODE
      NAME
      OWNER
      OSCODE
      RCODE
      Acres
      last_edited_date
    ].freeze

    def pull(since: nil, limit: 2_000) # rubocop:disable Lint/UnusedMethodArgument
      arcgis.query_geojson(
        path:       LAYER_PATH,
        where:      WHERE,
        out_fields: OUT_FIELDS,
        out_sr:     4326,
        limit:      limit
      ).filter_map { |feature| normalize(feature) }
    end

    private

    def arcgis
      @arcgis ||= Muni::Clients::Arcgis.new(base_url: self.class.base_url)
    end

    def normalize(feature)
      props = feature['properties'] || {}
      geometry = feature['geometry']
      location = Muni::Helpers::Geo.centroid(geometry)
      identifier = props['JOIN_ID'] || props['OBJECTID']
      fcode = props['FCODE']&.to_i
      return nil unless identifier && fcode && geometry.is_a?(Hash) && location

      emit(
        external_id: "parks/#{identifier}",
        hall:        'cambridge',
        name:        clean_string(props['NAME']) || "Park #{identifier}",
        owner:       clean_string(props['OWNER']),
        park_type:   PARK_FCODES.fetch(fcode, 'Park'),
        fcode:       fcode,
        oscode:      props['OSCODE']&.to_i,
        rcode:       props['RCODE']&.to_i,
        acres:       props['Acres']&.to_f,
        edited_at:   Muni::Helpers::Normalize.parse_time(props['last_edited_date']),
        location:    location,
        geometry:    geometry,
        source_url:  SOURCE_URL
      )
    end
  end
end
