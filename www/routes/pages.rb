require 'sinatra/base'
require 'muni'

module Muni
  module Www
    module Routes
      # HTML shell. The browser hydrates panes via /api/* fetches and
      # /stream/* SSE.
      class Pages < Sinatra::Base
        helpers HallResolution
        set :views, File.expand_path('../views', __dir__)
        set :public_folder, File.expand_path('../public', __dir__)
        set :host_authorization, { permitted_hosts: [] }

        get '/' do
          @hall = page_hall!
          response.set_cookie('hall', value: @hall.slug, path: '/', http_only: false)
          @halls = Muni::Hall.all
          @categories = Muni::View.for_hall(@hall.slug)
          counts = Muni::Store.counts_by_source(hall: @hall.slug)
          @initial_category = initial_category_for(@categories, @hall.slug, counts, params[:category])
          configure_map!
          erb :shell, layout: :layout
        end

        get '/status' do
          render_status
        end

        get '/water' do
          halt 404, 'Water Quality is not enabled' unless Muni::Water.enabled?
          if params[:hall] && (!Muni::Water::HALLS.include?(params[:hall]) || !public_hall(params[:hall]))
            halt 404, 'Water Quality is not available here'
          end
          redirect water_region_path
        end

        get '/water/charles' do
          halt 404, 'Water Quality is not enabled' unless Muni::Water.enabled?
          unless Muni::Water.presentation_enabled?
            halt 503, 'Charles River data views are being updated. Collection continues; please check back shortly.'
          end
          redirect water_region_path if Rack::Utils.parse_query(request.query_string).key?('hall')
          @water_region = true
          @water_view = %w[metrics map records datasets].include?(params[:view]) ? params[:view] : 'metrics'
          configure_map!
          erb :water, layout: :layout
        end

        def water_region_path
          query = Rack::Utils.build_query(params.reject { |key, _| key.to_s == 'hall' })
          query.empty? ? '/water/charles' : "/water/charles?#{query}"
        end

        get '/status.json' do
          content_type :json
          JSON.dump(Muni::Status.snapshot(hall: resolved_hall_slug))
        end

        get '/dashboard' do
          render_dashboard
        end

        get '/trends' do
          render_dashboard
        end

        def render_dashboard
          @hall = page_hall!
          response.set_cookie('hall', value: @hall.slug, path: '/', http_only: false)
          @categories = Muni::View.for_hall(@hall.slug)
          configure_map!
          erb :dashboard, layout: :layout
        end

        def render_status
          @status = Muni::Status.snapshot(hall: resolved_hall_slug)
          erb :status, layout: false
        end

        def h(value)
          Rack::Utils.escape_html(value.to_s)
        end

        get '/digest' do
          @hall = page_hall!
          response.set_cookie('hall', value: @hall.slug, path: '/', http_only: false)
          @categories = Muni::View.for_hall(@hall.slug)
          configure_map!
          erb :digest, layout: :layout
        end

        get '/meetings' do
          @hall = page_hall!
          halt 404, 'Meetings are not available for this Hall' unless @hall.meetings_enabled?
          response.set_cookie('hall', value: @hall.slug, path: '/', http_only: false)
          @categories = Muni::View.for_hall(@hall.slug)
          configure_map!
          erb :meetings, layout: :layout
        end

        get '/transit' do
          redirect '/mobility/subway', 301
        end

        get '/transit/subway' do
          redirect '/mobility/subway', 301
        end

        get '/mobility/subway' do
          @mobility_region = true
          configure_map!
          erb :subway, layout: :layout
        end

        get '/about' do
          @hall = page_hall!
          response.set_cookie('hall', value: @hall.slug, path: '/', http_only: false)
          configure_map!
          erb :about, layout: :layout
        end

        def initial_category_for(categories, hall_slug, counts, requested = nil)
          if requested
            cat = categories.find { |c| c.slug.to_s == requested.to_s }
            return cat.slug.to_s if cat
          end

          enabled = categories.find do |cat|
            row_count = Muni::View.category_row_count(cat.slug, hall_slug, counts)
            live = Muni::View.category_live?(cat.slug, hall_slug)
            row_count.positive? || live
          end
          (enabled || categories.first)&.slug&.to_s || 'service_requests'
        end

        def configure_map!
          @maptiler_key = ENV.fetch('MUNI_MAPTILER_KEY', '')
          @map_style = ENV.fetch('MUNI_MAP_STYLE', '')
          @map_tiles = map_tiles_env
          @pmtiles_url = ENV.fetch('MUNI_PMTILES_URL', '/tiles/muni.pmtiles')
          @pmtiles_ready = pmtiles_ready?(@pmtiles_url)
          @basemap_mode = ENV.fetch('MUNI_BASEMAP_MODE', default_basemap_mode)
          @basemap_error = basemap_error
        end

        def map_tiles_env
          raw = ENV.fetch('MUNI_MAP_TILES', '').strip
          return nil if raw.empty?

          tiles = raw.split(',').map(&:strip).reject(&:empty?)
          tiles.length == 1 ? tiles.first : tiles
        end

        def default_basemap_mode
          'auto'
        end

        def hosted_basemap_unset?
          @maptiler_key.empty? && @map_style.empty? && @map_tiles.nil?
        end

        def pmtiles_ready?(url)
          return false if url.to_s.empty?
          return true if url.start_with?('http://', 'https://')
          return false unless url.start_with?('/tiles/')

          rel = url.sub(%r{\A/tiles/?}, '')
          File.file?(File.join(tiles_dir, rel))
        end

        def tiles_dir
          ENV.fetch('MUNI_TILES_PATH', File.join(Muni::Config.data_dir, 'tiles'))
        end

        def basemap_error
          return nil unless @basemap_mode == 'pmtiles' && !@pmtiles_ready && hosted_basemap_unset?

          'Production basemap is not configured. Upload /data/tiles/muni.pmtiles or set a hosted tile provider.'
        end
      end
    end
  end
end
