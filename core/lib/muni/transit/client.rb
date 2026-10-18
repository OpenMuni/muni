# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'time'

module Muni
  module Transit
    # Light MBTA V3 API client with in-memory caching and graceful fallback.
    class Client
      BASE_URL = 'https://api-v3.mbta.com'
      DEFAULT_HEADERS = {
        'Accept' => 'application/vnd.api+json',
        'User-Agent' => 'Muni.fyi Transit Tracker (pair-programming)'
      }.freeze

      @cache = {}
      @cache_mutex = Mutex.new

      class << self
        def api_key
          ENV.fetch('MBTA_API_KEY', nil)
        end

        def vehicles(routes: %w[Red Orange Blue Green-B Green-C Green-D Green-E])
          route_param = Array(routes).join(',')
          cache_key = "vehicles:#{route_param}"
          cached = get_cached(cache_key, ttl_seconds: 5)
          return cached if cached

          path = "/vehicles?filter[route]=#{URI.encode_www_form_component(route_param)}&include=stop,trip"
          data = get(path)
          put_cached(cache_key, data)
        end

        def predictions(stop_id:)
          gtfs_id = Stations.canonical_id(stop_id)
          cache_key = "predictions:#{gtfs_id}"
          cached = get_cached(cache_key, ttl_seconds: 10)
          return cached if cached

          path = "/predictions?filter[stop]=#{URI.encode_www_form_component(gtfs_id)}&include=route,trip&sort=arrival_time"
          data = get(path)
          put_cached(cache_key, data)
        end

        def alerts(route: nil)
          cache_key = "alerts:#{route || 'all'}"
          cached = get_cached(cache_key, ttl_seconds: 60)
          return cached if cached

          path = route ? "/alerts?filter[route]=#{URI.encode_www_form_component(route)}" : '/alerts'
          data = get(path)
          put_cached(cache_key, data)
        end

        private

        def get(path)
          uri = URI.join(BASE_URL, path)
          req = Net::HTTP::Get.new(uri)
          DEFAULT_HEADERS.each { |k, v| req[k] = v }
          req['x-api-key'] = api_key if api_key && !api_key.empty?

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == 'https')
          http.open_timeout = 4
          http.read_timeout = 4

          res = http.request(req)
          return JSON.parse(res.body) if res.is_a?(Net::HTTPSuccess)

          { 'error' => "MBTA API returned status #{res.code}", 'data' => [] }
        rescue StandardError => e
          { 'error' => e.message, 'data' => [] }
        end

        def get_cached(key, ttl_seconds:)
          @cache_mutex.synchronize do
            entry = @cache[key]
            return nil unless entry

            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return entry[:data] if now - entry[:timestamp] < ttl_seconds

            @cache.delete(key)
            nil
          end
        end

        def put_cached(key, data)
          @cache_mutex.synchronize do
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            @cache[key] = { data: data, timestamp: now }
            data
          end
        end
      end
    end
  end
end
