require 'date'
require 'time'

module Boston
  module SharedCkan
    BASE_URL = 'https://data.boston.gov'.freeze

    def ckan
      @ckan ||= Muni::Clients::Ckan.new(base_url: BASE_URL)
    end

    def clean(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end

    def time(value)
      Muni::Helpers::Normalize.parse_time(value)
    end

    def point(lon, lat)
      Muni::Helpers::Geo.point(lon, lat)
    end

    def row_point(row, lon: %w[longitude long x_longitude POINT_X x], lat: %w[latitude lat y_latitude POINT_Y y])
      longitude = lon.filter_map { |field| row[field] }.find { |value| !value.to_s.strip.empty? }
      latitude = lat.filter_map { |field| row[field] }.find { |value| !value.to_s.strip.empty? }
      point(longitude, latitude)
    end

    def money(value)
      clean(value)&.gsub(/[^0-9.-]/, '')&.then { |text| Float(text) }
    rescue ArgumentError
      nil
    end

    def integer(value)
      return nil if clean(value).nil?

      Float(value).to_i
    rescue ArgumentError, TypeError
      nil
    end

    def truthy?(value)
      %w[1 true t yes y].include?(value.to_s.strip.downcase)
    end

    def dataset_url(package_id)
      "#{SharedCkan::BASE_URL}/dataset/#{package_id}"
    end

    def wkt_geometry(value)
      text = clean(value)
      return nil unless text

      if (match = text.match(/\APOINT\s*\(([-+0-9.e]+)\s+([-+0-9.e]+)\)\z/i))
        return { 'type' => 'Point', 'coordinates' => [match[1].to_f, match[2].to_f] }
      end
      if (match = text.match(/\APOLYGON\s*\(\((.*)\)\)\z/im))
        return { 'type' => 'Polygon', 'coordinates' => parse_wkt_rings(match[1]) }
      end

      if (match = text.match(/\AMULTIPOLYGON\s*\(\(\((.*)\)\)\)\z/im))
        polygons = match[1].split(/\)\)\s*,\s*\(\(/).map { |polygon| parse_wkt_rings(polygon) }
        return { 'type' => 'MultiPolygon', 'coordinates' => polygons }
      end
      nil
    end

    def parse_wkt_rings(text)
      text.split(/\)\s*,\s*\(/).map do |ring|
        ring.split(',').filter_map do |pair|
          lon, lat = pair.strip.split(/\s+/, 3)
          [Float(lon), Float(lat)] if lon && lat
        rescue ArgumentError
          nil
        end
      end
    end

    def sql_time(value)
      value.utc.strftime('%Y-%m-%d %H:%M:%S').gsub("'", "''")
    end

    def each_resource_row(package_id:, resource_name: nil, name_pattern: nil, fields: nil,
                          where: nil, order: nil, limit: nil, offset: 0, changed_only: false, &)
      unless block_given?
        return enum_for(__method__, package_id: package_id, resource_name: resource_name,
                        name_pattern: name_pattern, fields: fields, where: where, order: order,
                        limit: limit, offset: offset, changed_only: changed_only)
      end

      resource = ckan.resolve_resource(package_id, name: resource_name, name_pattern: name_pattern, fields: fields)
      signature_key = "ckan:resource:#{self.class.slug}:#{resource.fetch('id')}"
      signature = ckan.resource_signature(resource)
      return 0 if changed_only && Muni::Store.meta(signature_key) == signature

      read = ckan.each_sql(resource: resource.fetch('id'), where: where, order: order,
                           limit: limit, offset: offset, &)
      # A limited diagnostic pull has not reconciled the resource. Recording
      # its signature would make the next scheduled inventory refresh skip it.
      Muni::Store.set_meta(signature_key, signature) if changed_only && limit.nil? && offset.to_i.zero?
      read
    end

    def pull(**args)
      each_record(**args).to_a
    end
  end
end
