# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'time'

module Muni
  module Transit
    # Only MBTA V3 responses are represented as current subway data.
    class Client
      BASE_URL = 'https://api-v3.mbta.com'
      PAGE_LIMIT = 100
      MAX_PAGES = 50
      Error = Class.new(StandardError) do
        attr_reader :status

        def initialize(message, status: 503)
          @status = status
          super(message)
        end
      end

      @cache = {}
      @mutex = Mutex.new

      class << self
        def stations
          cached('stations', 86_400) do
            by_id = {}
            Transit::ROUTES.each do |route|
              pages('/stops', 'filter[route]' => route, 'filter[location_type]' => '1').each do |stop|
                attrs = stop.fetch('attributes', {})
                next unless attrs['location_type'] == 1 && stop['id'].to_s.start_with?('place-')

                station = by_id[stop['id']] ||= {
                  'id' => stop['id'], 'name' => attrs['name'], 'latitude' => attrs['latitude'],
                  'longitude' => attrs['longitude'], 'municipality' => attrs['municipality'], 'routes' => []
                }
                station['routes'] << route
              end
            end
            by_id.values.sort_by { |station| station['name'].to_s }
          end
        end

        def vehicles
          cached('vehicles', 5) do
            pages('/vehicles', 'filter[route]' => Transit::ROUTES.join(','))
              .filter_map do |row|
                route = row.dig('relationships', 'route', 'data', 'id')
                next unless Transit::ROUTES.include?(route)

                attrs = row.fetch('attributes', {})
                next unless attrs['latitude'] && attrs['longitude']

                { 'id' => row['id'], 'route' => route, 'latitude' => attrs['latitude'],
                  'longitude' => attrs['longitude'], 'bearing' => attrs['bearing'],
                  'current_status' => attrs['current_status'], 'updated_at' => attrs['updated_at'] }
              end
          end
        end

        def predictions(stop_id:)
          raise Error.new('Unknown subway station', status: 404) unless stop_id.match?(/\Aplace-[a-z0-9]+\z/)
          raise Error.new('Unknown subway station', status: 404) unless parent_station?(stop_id)

          cached("predictions:#{stop_id}", 10) do
            pages('/predictions', 'filter[stop]' => stop_id, 'filter[route]' => Transit::ROUTES.join(','),
                                  'sort' => 'arrival_time')
              .filter_map do |row|
                route = row.dig('relationships', 'route', 'data', 'id')
                next unless Transit::ROUTES.include?(route)

                attrs = row.fetch('attributes', {})
                { 'id' => row['id'], 'route' => route, 'stop_id' => stop_id,
                  'arrival_time' => attrs['arrival_time'], 'departure_time' => attrs['departure_time'],
                  'status' => attrs['status'], 'updated_at' => attrs['updated_at'],
                  'direction_id' => attrs['direction_id'], 'schedule_relationship' => attrs['schedule_relationship'] }
              end
          end
        end

        def alerts
          cached('alerts', 60) do
            pages('/alerts', 'filter[route]' => Transit::ROUTES.join(','), 'filter[activity]' => 'BOARD,EXIT,RIDE')
              .filter_map do |row|
                attrs = row.fetch('attributes', {})
                now = Time.now.utc
                active = Array(attrs['active_period']).any? do |period|
                  start_at = period['start'] && Time.parse(period['start'])
                  end_at = period['end'] && Time.parse(period['end'])
                  (!start_at || start_at <= now) && (!end_at || end_at > now)
                end
                next unless active

                routes = Array(attrs['informed_entity']).filter_map { |entity| entity['route'] }
                routes = (routes & Transit::ROUTES).uniq
                next if routes.empty?

                { 'id' => row['id'], 'routes' => routes, 'header' => attrs['header'],
                  'description' => attrs['description'], 'effect' => attrs['effect'],
                  'updated_at' => attrs['updated_at'] }
              end
          end
        end

        def clear_cache!
          @mutex.synchronize { @cache.clear }
        end

        private

        def parent_station?(id)
          cached("station:#{id}", 86_400) do
            stop = request(URI.join(BASE_URL, "/stops/#{id}")).fetch('data')
            stop['id'] == id && stop.dig('attributes', 'location_type') == 1
          end.fetch('data')
        rescue Error => e
          raise Error.new('Unknown subway station', status: 404) if e.status == 404

          raise
        end

        def cached(key, ttl)
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          entry = @mutex.synchronize { @cache[key] }
          return entry[:response] if entry && now - entry[:at] < ttl

          response = { 'data' => yield, 'fetched_at' => Time.now.utc.iso8601 }
          @mutex.synchronize { @cache[key] = { at: now, response: response } }
          response
        end

        def pages(path, params)
          uri = URI.join(BASE_URL, path)
          uri.query = URI.encode_www_form(params.merge('page[limit]' => PAGE_LIMIT))
          data = []
          seen = {}
          MAX_PAGES.times do
            raise Error, 'MBTA pagination loop' if seen[uri.to_s]

            seen[uri.to_s] = true
            body = request(uri)
            raise Error, 'Invalid MBTA response' unless body['data'].is_a?(Array)

            data.concat(body['data'])
            link = body.dig('links', 'next')
            return data if link.nil? || link.empty?

            uri = URI.join(BASE_URL, link)
            raise Error, 'Invalid MBTA pagination URL' unless uri.scheme == 'https' && uri.host == URI(BASE_URL).host
          end
          raise Error, 'MBTA pagination limit exceeded'
        end

        def request(uri)
          req = Net::HTTP::Get.new(uri)
          req['Accept'] = 'application/vnd.api+json'
          req['User-Agent'] = 'Muni subway'
          key = ENV.fetch('MBTA_API_KEY', '')
          req['x-api-key'] = key unless key.empty?
          response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 5) do |http|
            http.request(req)
          end
          unless response.is_a?(Net::HTTPSuccess)
            status = { 404 => 404, 429 => 429 }.fetch(response.code.to_i, 503)
            raise Error.new("MBTA data unavailable (HTTP #{response.code})", status: status)
          end

          JSON.parse(response.body)
        rescue JSON::ParserError, Timeout::Error, SocketError, SystemCallError => e
          raise Error, "MBTA data unavailable (#{e.class})"
        end
      end
    end
  end
end
