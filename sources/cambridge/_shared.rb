require 'muni/source'
require 'muni/clients/socrata'

module Cambridge
  module SharedSoda
    BASE_URL = 'https://data.cambridgema.gov'.freeze

    def socrata
      @socrata ||= Muni::Clients::Socrata.new(base_url: SharedSoda::BASE_URL)
    end

    def soql_since(since)
      Muni::Helpers::Normalize.sql_timestamp(since)
    end

    def bounded_since(since, days:)
      floor = Time.now.utc - (days * 86_400)
      since ? [since, floor].max : floor
    end

    def clean_string(value)
      text = value.to_s.gsub(/\s+/, ' ').strip
      text.empty? ? nil : text
    end

    # Parse currency/number strings like "$42,019,744" or "299,954" into a Float.
    # Plain String#to_f returns 0.0 for a leading "$" and stops at the first comma.
    def money(value)
      digits = value.to_s.gsub(/[^\d.]/, '')
      digits.empty? ? nil : digits.to_f
    end

    def location_coords(value)
      return nil unless value.is_a?(Hash)

      coords = value['coordinates']
      return coords if coords

      lon = value['longitude']
      lat = value['latitude']
      return [lon, lat] if lon && lat

      nil
    end
  end
end
