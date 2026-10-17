require 'sinatra/base'

module Muni
  module Www
    module Routes
      class WaterAPI < Sinatra::Base
        set :host_authorization, { permitted_hosts: [] }

        before '/api/water/*' do
          content_type :json
          halt 404, JSON.generate(error: 'Water Quality is not enabled') unless Muni::Water.enabled?
          unless Muni::Water.presentation_enabled? || request.path_info.end_with?('/coverage')
            halt 503, JSON.generate(error: 'Charles River data views are being updated; collection continues.')
          end
          if params['hall'] && !Muni::Water::HALLS.include?(params['hall'])
            halt 404, JSON.generate(error: 'Water Quality is not available for this municipality')
          end
        end

        helpers do
          def water_query
            Muni::Water::Query.new(include_coverage: params['include_coverage'] != '0')
          end
        end

        error Muni::Water::Error do
          status 400
          JSON.generate(error: env['sinatra.error'].message)
        end

        get('/api/water/charles') { Muni::Water.json(water_query.overview) }
        get('/api/water/charles/metrics') { Muni::Water.json(water_query.metrics) }
        get('/api/water/charles/geojson') { Muni::Water.json(water_query.geojson) }
        get('/api/water/charles/series') { Muni::Water.json(water_query.series(params)) }
        get('/api/water/charles/trends') { Muni::Water.json(Muni::Water::Trends.new(include_coverage: params['include_coverage'] != '0').call(params)) }
        get('/api/water/charles/events') { Muni::Water.json(water_query.records(params, kind: 'discharge')) }
        get('/api/water/charles/records') { Muni::Water.json(water_query.records(params)) }
        get('/api/water/charles/signals') { Muni::Water.json(water_query.signals(params)) }
        get '/api/water/charles/signals/:id/evidence' do
          Muni::Water.json(water_query.signal_evidence(params['id'], params))
        end
        get('/api/water/charles/coverage') { Muni::Water.json(water_query.envelope) }
        get '/api/water/charles/evidence/:id' do
          Muni::Water.json(water_query.evidence(params['id'], revision: params['revision'],
                                                              cutoff:   params['cutoff']))
        end

        get '/api/water/charles/export.csv' do
          csv, page = water_query.export(params)
          content_type 'text/csv'
          attachment 'charles-water-evidence.csv'
          headers 'X-Total-Count' => page[:total].to_s, 'X-Next-Offset' => page[:next_offset].to_s
          headers 'X-Next-Cursor' => page[:next_cursor].to_s, 'X-Revision-Cutoff' => page[:revision_cutoff].to_s
          csv
        end
      end
    end
  end
end
