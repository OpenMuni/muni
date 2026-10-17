module Muni
  module Helpers
    module Geo
      module_function

      def point(lon, lat)
        return nil if lon.nil? || lat.nil?

        longitude = Float(lon)
        latitude = Float(lat)
        return nil unless longitude.between?(-180, 180) && latitude.between?(-90, 90)

        [longitude, latitude]
      rescue ArgumentError, TypeError
        nil
      end

      def centroid(geometry)
        coords = coordinate_pairs(geometry)
        return nil if coords.empty?

        lon = coords.sum { |pair| pair[0].to_f } / coords.length
        lat = coords.sum { |pair| pair[1].to_f } / coords.length
        point(lon, lat)
      end

      def coordinate_pairs(value)
        case value
        when Hash
          coordinate_pairs(value['coordinates'] || value[:coordinates])
        when Array
          if value.length >= 2 && value[0].is_a?(Numeric) && value[1].is_a?(Numeric)
            [[value[0], value[1]]]
          else
            value.flat_map { |item| coordinate_pairs(item) }
          end
        else
          []
        end
      end

      def distance_meters(lat1, lon1, lat2, lon2)
        return nil if [lat1, lon1, lat2, lon2].any?(&:nil?)

        radius = 6_371_000.0
        rad = Math::PI / 180
        lat1 = lat1.to_f * rad
        lat2 = lat2.to_f * rad
        dlat = lat2 - lat1
        dlon = (lon2.to_f - lon1.to_f) * rad
        a = (Math.sin(dlat / 2)**2) +
            (Math.cos(lat1) * Math.cos(lat2) * (Math.sin(dlon / 2)**2))
        radius * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
      end

      def bbox_contains?(bbox, lon, lat)
        return false if bbox.nil? || lon.nil? || lat.nil?

        west, south, east, north = bbox
        lon.between?(west, east) && lat.between?(south, north)
      end

      def boundary_contains?(boundary, lon, lat)
        return true if boundary.nil? || boundary.empty?
        return false if lon.nil? || lat.nil?

        case boundary['type'] || boundary[:type]
        when 'Polygon'
          polygon_contains?(boundary['coordinates'] || boundary[:coordinates], lon.to_f, lat.to_f)
        when 'MultiPolygon'
          polygons = boundary['coordinates'] || boundary[:coordinates]
          polygons.any? { |rings| polygon_contains?(rings, lon.to_f, lat.to_f) }
        else
          false
        end
      end

      def polygon_contains?(rings, lon, lat)
        return false unless rings&.first

        contains = ring_contains?(rings.first, lon, lat)
        holes = rings[1..] || []
        contains && holes.none? { |ring| ring_contains?(ring, lon, lat) }
      end

      def ring_contains?(ring, lon, lat)
        inside = false
        j = ring.length - 1
        ring.each_with_index do |point, i|
          from_lon, from_lat = point
          to_lon, to_lat = ring[j]
          return true if point_on_segment?(lon, lat, from_lon, from_lat, to_lon, to_lat)

          intersects = ((from_lat > lat) != (to_lat > lat)) &&
                       (lon < ((to_lon - from_lon) * (lat - from_lat) / (to_lat - from_lat)) + from_lon)
          inside = !inside if intersects
          j = i
        end
        inside
      end

      def point_on_segment?(lon, lat, from_lon, from_lat, to_lon, to_lat)
        cross = ((lat - from_lat) * (to_lon - from_lon)) - ((lon - from_lon) * (to_lat - from_lat))
        return false unless cross.abs < 1e-10

        lon.between?([from_lon, to_lon].min, [from_lon, to_lon].max) &&
          lat.between?([from_lat, to_lat].min, [from_lat, to_lat].max)
      end

      def to_geojson(records, geometry: :location)
        features = records.compact.map do |r|
          feature_geometry, geom_field = feature_geometry(r, geometry)
          next nil if feature_geometry.nil?

          { type:       'Feature',
            geometry:   feature_geometry,
            properties: feature_properties(r, geom_field) }
        end.compact

        { type: 'FeatureCollection', features: features }
      end

      def feature_geometry(record, geometry)
        if geometry == :location && record.respond_to?(:geometry)
          geom = record.geometry
          return [stringify_keys(geom), :geometry] if geojson_geometry?(geom)
        end

        coords = record.respond_to?(geometry) ? record.public_send(geometry) : nil
        return [nil, geometry] if coords.nil?

        [{ type: 'Point', coordinates: coords }, geometry]
      end

      def geojson_geometry?(value)
        type = value.is_a?(Hash) && (value['type'] || value[:type])
        %w[Point Polygon MultiPolygon].include?(type.to_s) && coordinate_pairs(value).any?
      end

      def feature_properties(record, geom_field)
        if record.respond_to?(:to_h)
          attrs = record.to_h.reject { |k, _| k == geom_field }
          attrs = attrs.merge(Muni::ServiceRequestPolicy.enrich(attrs)) if record.is_a?(Muni::Records::ServiceRequest)
          return stringify_times(attrs)
        end

        {}
      end

      def stringify_keys(value)
        case value
        when Hash
          value.to_h { |key, item| [key.to_s, stringify_keys(item)] }
        when Array
          value.map { |item| stringify_keys(item) }
        else
          value
        end
      end

      def stringify_times(value)
        case value
        when Time
          value.utc.iso8601
        when Array
          value.map { |item| stringify_times(item) }
        when Hash
          value.transform_values { |item| stringify_times(item) }
        else
          value
        end
      end
    end
  end
end
