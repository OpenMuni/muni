require 'sinatra/base'
require 'json'
require 'time'
require 'muni'

Muni.boot!
Muni::Hall.load_all!

require_relative 'routes/hall_resolution'
require_relative 'routes/api'
require_relative 'routes/water'
require_relative 'routes/stream'
require_relative 'routes/pages'
require_relative 'routes/tiles'

module Muni
  module Www
    module ReadinessHelpers
      def readiness_payload
        counts = Muni::Store.counts_by_source
        sources = source_readiness(counts)
        beats = beat_readiness
        source_data = source_data_readiness
        basemap = basemap_readiness
        ready = sources.values.all? && beats.values.all? && source_data.values.all? && basemap[:ready]

        {
          ready:       ready,
          version:     Muni::VERSION,
          counts:      counts,
          sources:     sources,
          beats:       beats,
          source_data: source_data,
          basemap:     basemap,
          checked_at:  Time.now.utc.iso8601
        }
      rescue StandardError => e
        {
          ready:      false,
          error:      "#{e.class}: #{e.message}",
          checked_at: Time.now.utc.iso8601
        }
      end

      def source_readiness(counts)
        Muni::Get::Registry.category_source_slugs.reject { |slug| slug.start_with?('water/') }.to_h do |slug|
          [slug, counts.fetch(slug, 0).positive?]
        end
      end

      def beat_readiness
        now = Time.now.utc

        Muni::Registry.beats.reject { |slug, _| slug.start_with?('water/') }.to_h do |slug, beat_class|
          last = Muni::Store.latest_beat_run(slug, successful: true)
          ended_at = parse_time(last && last[:ended_at])
          max_age = readiness_max_beat_age(beat_class)
          fresh = ended_at && (now - ended_at <= max_age)
          [slug, !!fresh]
        end
      end

      def source_data_readiness(now = Time.now.utc)
        critical_sources.to_h do |source|
          [source.slug, critical_source_data_fresh?(source, now)]
        end
      end

      def critical_source_data_fresh?(source, now)
        klass = source.emits
        latest = [
          Muni::Store.latest_time(klass, hall: source.hall, time_field: :opened_at),
          Muni::Store.latest_time(klass, hall: source.hall, time_field: :updated_at),
          Muni::Store.latest_time(klass, hall: source.hall)
        ].compact.max
        !!(latest && (now - latest <= readiness_max_source_lag))
      end

      def critical_sources
        Muni::Registry.sources.values.select do |source|
          source.criticality == :critical || source.slug == 'cambridge/service_requests'
        end
      end

      def readiness_max_source_lag
        ENV.fetch('MUNI_READY_MAX_SOURCE_LAG_SECONDS', '172800').to_i
      end

      def readiness_max_beat_age(beat_class)
        override = ENV.fetch('MUNI_READY_MAX_BEAT_AGE_SECONDS', nil).to_i
        return override if override.positive?

        grace = ENV.fetch('MUNI_READY_BEAT_GRACE_SECONDS', '10800').to_i
        beat_class.every_seconds + grace
      end

      def basemap_readiness
        mode = ENV.fetch('MUNI_BASEMAP_MODE', 'auto')
        pmtiles_ready = pmtiles_ready?
        hosted_ready = hosted_basemap_ready?
        ready = mode != 'pmtiles' || pmtiles_ready || hosted_ready

        {
          ready:         ready,
          mode:          mode,
          pmtiles_ready: pmtiles_ready,
          hosted_ready:  hosted_ready
        }
      end

      def pmtiles_ready?
        url = ENV.fetch('MUNI_PMTILES_URL', '/tiles/muni.pmtiles')
        return true if url.start_with?('http://', 'https://')
        return false unless url.start_with?('/tiles/')

        relative = url.sub(%r{\A/tiles/?}, '')
        File.file?(File.join(tiles_dir, relative))
      end

      def hosted_basemap_ready?
        %w[MUNI_MAP_STYLE MUNI_MAPTILER_KEY MUNI_MAP_TILES].any? { |key| ENV[key].to_s.strip != '' }
      end

      def tiles_dir
        ENV.fetch('MUNI_TILES_PATH') { File.join(Muni::Config.data_dir, 'tiles') }
      end

      def parse_time(value)
        return nil unless value
        return value.utc if value.respond_to?(:utc)

        Time.parse(value.to_s).utc
      end
    end

    class App < Sinatra::Base
      helpers ReadinessHelpers

      configure do
        set :root, __dir__
        set :views, File.expand_path('views', __dir__)
        set :public_folder, File.expand_path('public', __dir__)
        set :show_exceptions, :after_handler if development?
        set :host_authorization, { permitted_hosts: [] }
        Muni::Store.ensure_tables!
      end

      use Routes::Tiles
      use Routes::WaterAPI
      use Routes::API
      use Routes::Stream
      use Routes::Pages

      get '/healthz' do
        content_type :json
        live_beats = Muni::Registry.beats.keys
        last = Muni::Store.recent_beat_runs(limit: 100).find { |row| live_beats.include?(row[:beat_slug]) }
        JSON.dump(
          ok:        true,
          version:   Muni::VERSION,
          counts:    Muni::Store.counts_by_source,
          last_beat: last && {
            slug:       last[:beat_slug],
            started_at: last[:started_at].utc.iso8601,
            error:      last[:error]
          }
        )
      end

      get '/readyz' do
        content_type :json
        payload = readiness_payload
        status(payload[:ready] ? 200 : 503)
        JSON.dump(payload)
      end

      not_found do
        content_type :text
        'not found'
      end
    end
  end
end
