# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Muni::Www::App do
  def app
    described_class
  end

  before { Muni::Store.ensure_tables! }

  describe 'GET /transit' do
    it 'renders the transit command center shell for Cambridge' do
      get '/transit?hall=cambridge'

      expect(last_response).to be_ok
      expect(last_response.body).to include('id="root"')
      expect(last_response.body).to include('transit-viewport')
      expect(last_response.body).to include('/transit/assets/index.js')
      expect(last_response.body).to include('/transit/assets/index.css')
      expect(last_response.body).to include('window.MUNI_HALL = "cambridge"')
    end

    it 'renders the transit shell for Boston' do
      get '/transit?hall=boston'

      expect(last_response).to be_ok
      expect(last_response.body).to include('id="root"')
      expect(last_response.body).to include('window.MUNI_HALL = "boston"')
    end
  end

  describe 'GET /api/transit/stations' do
    it 'returns stations scoped by hall' do
      get '/api/transit/stations?hall=cambridge'

      expect(last_response).to be_ok
      data = JSON.parse(last_response.body)
      expect(data).to be_an(Array)
      expect(data.length).to be >= 5
      expect(data.map { |s| s['id'] }).to include('place-alfcl', 'place-porter', 'place-hvd', 'place-knn')
      expect(data.all? { |s| s['hall'] == 'cambridge' }).to be true
    end

    it 'returns GeoJSON format' do
      get '/api/transit/stations.geojson?hall=cambridge'

      expect(last_response).to be_ok
      geojson = JSON.parse(last_response.body)
      expect(geojson['type']).to eq('FeatureCollection')
      expect(geojson['features']).not_to be_empty
    end
  end

  describe 'GET /api/transit/performance' do
    it 'returns municipal performance metrics' do
      get '/api/transit/performance?hall=cambridge'

      expect(last_response).to be_ok
      data = JSON.parse(last_response.body)
      expect(data['hall']).to eq('cambridge')
      expect(data['corridor_count']).to eq(4)
      expect(data['average_otp']).to be > 80.0
      expect(data['slow_zones_cleared']).to be > 0
    end

    it 'returns systemwide performance metrics when no hall is specified' do
      get '/api/transit/performance'

      expect(last_response).to be_ok
      data = JSON.parse(last_response.body)
      expect(data['overall_otp']).to eq(89.6)
      expect(data['slow_zones_removed_systemwide']).to eq(228)
    end
  end

  describe 'GET /api/transit/predictions/:stop_id' do
    it 'returns prediction payload' do
      allow(Muni::Transit).to receive(:predictions).with(stop_id: 'place-hvd').and_return({ 'data' => [] })
      get '/api/transit/predictions/place-hvd'

      expect(last_response).to be_ok
      data = JSON.parse(last_response.body)
      expect(data).to eq({ 'data' => [] })
    end
  end

  describe 'GET /api/transit/alerts' do
    it 'returns alerts payload' do
      allow(Muni::Transit).to receive(:alerts).with(route: nil).and_return({ 'data' => [] })
      get '/api/transit/alerts'

      expect(last_response).to be_ok
      data = JSON.parse(last_response.body)
      expect(data).to eq({ 'data' => [] })
    end
  end
end
