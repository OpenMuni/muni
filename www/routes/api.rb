require 'sinatra/base'
require 'json'
require 'muni'

module Muni
  module Www
    module Routes
      class API < Sinatra::Base
        helpers HallResolution
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

        get '/api/category/:slug/records' do
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
      end
    end
  end
end
