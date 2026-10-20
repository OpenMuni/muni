require 'sinatra/base'
require 'json'
require 'muni'
require 'muni/public_response_cache'

module Muni
  module Www
    module Routes
      class API < Sinatra::Base
        PUBLIC_CACHE = Muni::PublicResponseCache.new

        helpers HallResolution
        helpers do
          def cached_public_json
            headers 'Cache-Control' => 'public, max-age=0, must-revalidate'
            # A cached map can cross a rolling age boundary without any write.
            # SQL is bounded by the report-date index; evaluate it at request time.
            return JSON.generate(yield) if request.path_info.end_with?('/map') || params['cell']

            changes = %w[boston cambridge].map { |hall| Muni::Store.meta("changed_at:#{hall}/service_requests") }
            key = [Muni::Config.db_path, '311-map-v2', request.path_info, params.sort, changes].to_json
            PUBLIC_CACHE.fetch(key) { JSON.generate(yield) }
          end

          def service_request_page(sources: nil, compact: true, maximum: 200, metadata: true)
            query = Muni::Data::Query.new(params).service_request_query(sources: sources)
            query.page(compact: compact, maximum: maximum, metadata: metadata)
          end

          def service_request_array(sources: nil, metadata: true)
            page = JSON.parse(cached_public_json do
              service_request_page(sources: sources, compact: false, maximum: 500, metadata: metadata)
            end)
            if page['next_cursor']
              query = Rack::Utils.build_query(request.GET.merge('cursor' => page['next_cursor']))
              headers 'Link' => "<#{request.path_info}?#{query}>; rel=\"next\""
            end
            JSON.generate(page.fetch('items'))
          end
        end

        error Muni::ServiceRequestQuery::Invalid do
          status 400
          JSON.generate(error: env['sinatra.error'].message)
        end

        error Muni::ServiceRequestMap::Incomplete do
          status 503
          headers 'Retry-After' => '30'
          JSON.generate(error: 'map projection is incomplete')
        end
        set :host_authorization, { permitted_hosts: [] }

        before do
          apply_host_hall_param!
          if params[:hall] && !params[:hall].to_s.empty? && !public_hall(params[:hall])
            halt 404, JSON.dump(error: "unknown Hall: #{params[:hall]}")
          end
          content_type :json
        end

        get '/api/halls' do
          JSON.dump(Muni::Data.halls)
        end

        get '/api/sources' do
          JSON.dump(Muni::Data.sources(hall: params[:hall]))
        end

        get '/api/categories' do
          JSON.dump(Muni::Data.categories(hall: params[:hall]))
        end

        get '/api/dashboard' do
          JSON.dump(Muni::Data.dashboard(hall: params[:hall] || 'cambridge'))
        rescue Muni::Data::NotFound => e
          halt 404, JSON.dump(error: e.message)
        end

        get '/api/status' do
          JSON.dump(Muni::Status.snapshot(hall: params[:hall] || 'cambridge'))
        end

        get '/api/digest' do
          JSON.dump(Muni::Data.digest(hall: params[:hall] || 'cambridge'))
        rescue Muni::Data::NotFound => e
          halt 404, JSON.dump(error: e.message)
        end

        get '/api/meetings' do
          hall = Muni::Hall.find(params[:hall] || 'cambridge')
          halt 404, JSON.dump(error: 'meetings unavailable') unless hall&.meetings_enabled?
          limit = params[:limit] ? params[:limit].to_i : 50
          JSON.dump(Muni::Data.meetings(hall: params[:hall] || 'cambridge', limit: limit))
        rescue Muni::Data::NotFound => e
          halt 404, JSON.dump(error: e.message)
        end

        get '/api/meetings/:clip_id' do
          hall = params[:hall] || 'cambridge'
          JSON.dump(Muni::Data.record_for_type('meetings', id: "#{hall}/meetings/#{params[:clip_id]}"))
        rescue Muni::Data::NotFound => e
          halt 404, JSON.dump(error: e.message)
        end

        get '/api/predictions/:type' do
          JSON.dump(Muni::Data.prediction(type: params[:type], hall: params[:hall] || 'cambridge',
                                          limit: params[:limit], attrs: params))
        rescue Muni::Data::NotFound => e
          halt 404, JSON.dump(error: e.message)
        end

        get '/api/parking/check' do
          JSON.dump(
            Muni::Data.parking_check(
              hall:             params[:hall] || 'cambridge',
              lat:              params[:lat],
              lon:              params[:lon],
              arrive_at:        params[:arrive_at],
              duration_minutes: params[:duration_minutes]
            )
          )
        rescue Muni::Data::NotFound => e
          halt 404, JSON.dump(error: e.message)
        rescue Muni::Data::Error => e
          halt 400, JSON.dump(error: e.message)
        end

        get '/api/category/service_requests/page' do
          cached_public_json { service_request_page }
        end

        get '/api/category/service_requests/map' do
          cached_public_json { Muni::Data::Query.new(params).service_request_query.map }
        end

        get '/api/category/:slug/records' do
          next service_request_array if params[:slug] == 'service_requests'

          JSON.dump(Muni::Data.category_records(slug: params[:slug], hall: params[:hall], params: params))
        rescue Muni::Data::NotFound => e
          halt 404, JSON.dump(error: e.message)
        rescue Muni::Data::Error => e
          halt 400, JSON.dump(error: e.message)
        end

        get '/api/category/:slug/geo' do
          JSON.dump(Muni::Data.category_geo(slug: params[:slug], hall: params[:hall], params: params))
        rescue Muni::Data::NotFound => e
          halt 404, JSON.dump(error: e.message)
        rescue Muni::Data::Error => e
          halt 400, JSON.dump(error: e.message)
        end

        get '/api/category/:slug/facets' do
          JSON.dump(Muni::Data.category_facets(slug: params[:slug], hall: params[:hall], params: params))
        rescue Muni::Data::NotFound => e
          halt 404, JSON.dump(error: e.message)
        end

        get '/api/records/:scope/:name' do
          if params[:name] == 'service_requests' && Muni::Registry.source("#{params[:scope]}/#{params[:name]}")
            next service_request_array(sources: ["#{params[:scope]}/#{params[:name]}"], metadata: false)
          end

          JSON.dump(Muni::Data.source_records(scope: params[:scope], name: params[:name], params: params))
        rescue Muni::Data::NotFound => e
          halt 404, JSON.dump(error: e.message)
        end

        get '/api/facets/:scope/:name' do
          JSON.dump(Muni::Data.source_facets(scope: params[:scope], name: params[:name], params: params))
        rescue Muni::Data::NotFound => e
          halt 404, JSON.dump(error: e.message)
        end

        get '/api/records/:scope/:name/*' do
          JSON.dump(Muni::Data.source_record(scope: params[:scope], name: params[:name], id: params['splat'].first))
        rescue Muni::Data::NotFound => e
          halt 404, JSON.dump(error: e.message)
        end

        get '/api/records/:scope/:name/:id' do
          JSON.dump(Muni::Data.source_record(scope: params[:scope], name: params[:name], id: params[:id]))
        rescue Muni::Data::NotFound => e
          halt 404, JSON.dump(error: e.message)
        end

        get '/api/geo/:scope/:name' do
          JSON.dump(Muni::Data.source_geo(scope: params[:scope], name: params[:name], params: params))
        rescue Muni::Data::NotFound => e
          halt 404, JSON.dump(error: e.message)
        end

        get '/api/mobile/bootstrap' do
          JSON.dump(
            Muni::Data.bootstrap(
              hall:     params[:hall] || 'cambridge',
              category: params[:category] || 'service_requests'
            )
          )
        rescue Muni::Data::NotFound => e
          halt 404, JSON.dump(error: e.message)
        end

        get '/api/mobility/subway/stations' do
          subway_response { Muni::Transit.stations }
        end

        get '/api/mobility/subway/vehicles' do
          subway_response { Muni::Transit.vehicles }
        end

        get '/api/mobility/subway/predictions/:stop_id' do
          subway_response { Muni::Transit.predictions(stop_id: params[:stop_id]) }
        end

        get '/api/mobility/subway/alerts' do
          subway_response { Muni::Transit.alerts }
        end

        def subway_response
          JSON.dump(yield)
        rescue Muni::Transit::Client::Error => e
          halt e.status, JSON.dump(error: e.message, data: [], fetched_at: nil)
        end
      end
    end
  end
end
