require 'cgi'
require 'muni/helpers/http'

module Cambridge
  class LocationResolver
    CAMBRIDGE_BBOX = [-71.160, 42.355, -71.063, 42.405].freeze
    CENSUS_BASE = 'https://geocoding.geo.census.gov'.freeze
    NOMINATIM_BASE = 'https://nominatim.openstreetmap.org'.freeze

    def initialize(census: nil, nominatim: nil, sleep_seconds: ENV.fetch('MUNI_GEOCODER_SLEEP', '15').to_f)
      @census = census || Muni::Helpers::Http.new(base_url: CENSUS_BASE)
      @nominatim = nominatim || nominatim_client
      @sleep_seconds = sleep_seconds
      @cache = {}
      @last_nominatim_at = nil
    end

    def call(label)
      key = normalize_label(label)
      return nil if key.nil? || key.empty?

      @cache.fetch(key) do
        @cache[key] = geocode(key)
      end
    end

    private

    def geocode(label)
      query = "#{expand_abbreviations(label)}, Cambridge, MA"
      point = census_point(query) || nominatim_point(query)
      in_cambridge?(point) ? point : nil
    rescue StandardError
      nil
    end

    def census_point(query)
      data = @census.get('/geocoder/locations/onelineaddress',
                         { address: query, benchmark: 'Public_AR_Current', format: 'json' })
      coords = data.dig('result', 'addressMatches', 0, 'coordinates')
      coords && Muni::Helpers::Geo.point(coords['x'], coords['y'])
    rescue Muni::Helpers::Http::Error
      nil
    end

    def nominatim_point(query)
      return nil unless @nominatim

      throttle_nominatim
      data = @nominatim.get('/search',
                            { q: query, format: 'jsonv2', limit: 1,
                              countrycodes: 'us',
                              viewbox: CAMBRIDGE_BBOX.join(','),
                              bounded: 1,
                              addressdetails: 0 })
      row = Array(data).first
      row && Muni::Helpers::Geo.point(row['lon'], row['lat'])
    rescue Muni::Helpers::Http::Error
      nil
    end

    def nominatim_client
      base_url = ENV.fetch('MUNI_NOMINATIM_URL', nil)
      return Muni::Helpers::Http.new(base_url: base_url) if base_url
      return nil unless ENV.fetch('MUNI_ENABLE_PUBLIC_NOMINATIM', nil) == '1'

      Muni::Helpers::Http.new(base_url: NOMINATIM_BASE)
    end

    def throttle_nominatim
      return unless @last_nominatim_at && @sleep_seconds.positive?

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_nominatim_at
      sleep(@sleep_seconds - elapsed) if elapsed < @sleep_seconds
    ensure
      @last_nominatim_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def normalize_label(label)
      label.to_s.strip
           .gsub(/\s+/, ' ')
           .gsub(/\s*&\s*/, ' & ')
           .upcase
    end

    def expand_abbreviations(label)
      label
        .gsub(/\bMASS\b\.?/, 'MASSACHUSETTS')
        .gsub(/\bMT\b\.?/, 'MOUNT')
        .gsub(/\bMNSR\b\.?/, 'MONSIGNOR')
        .gsub(/\bPKWY\b\.?/, 'PARKWAY')
        .gsub(/\bAVE\b\.?/, 'AVENUE')
        .gsub(/\bST\b\.?/, 'STREET')
        .gsub(/\bRD\b\.?/, 'ROAD')
        .gsub(/\bPL\b\.?/, 'PLACE')
        .gsub(/\bHWY\b\.?/, 'HIGHWAY')
    end

    def in_cambridge?(point)
      return false unless point

      lon, lat = point
      west, south, east, north = CAMBRIDGE_BBOX
      lon.between?(west, east) && lat.between?(south, north)
    end
  end
end
