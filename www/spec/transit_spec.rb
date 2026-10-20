# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Muni::Www::App do
  def app = described_class

  before { Muni::Store.ensure_tables! }

  it 'uses the regional subway path and redirects legacy URLs' do
    %w[/transit /transit/subway].each do |path|
      get path
      expect(last_response.status).to eq(301)
      expect(last_response.headers['location']).to end_with('/mobility/subway')
    end
    get '/mobility/subway'
    expect(last_response).to be_ok
    expect(last_response.body).to include('MBTA Subway', '/js/subway.js')
    expect(last_response.body).not_to include('/transit/assets/index.js', 'Charles River', '/water/charles')
  end

  it 'offers only city home pages in the subway selector and preserves the selected city' do
    get '/mobility/subway?hall=boston'
    expect(last_response.body).to include('action="/"', 'value="cambridge"', 'value="boston" selected',
                                          'aria-label="Municipality"', 'href="/?hall=boston"')
    expect(last_response.body).not_to include('value="subway"')
    expect(last_response.headers['set-cookie'].to_s).to include('hall=boston')
    expect(last_response.body).to include('this.form.requestSubmit()')
    get '/?hall=boston'
    expect(last_response).to be_ok
  end

  it 'uses a left arrivals sidebar and an unobstructed map without route or notification controls' do
    get '/mobility/subway'
    body = last_response.body
    expect(body).to include('id="subway-sidebar"', 'Station arrivals', 'Service alerts', 'id="subway-map"')
    expect(body).to include(
      'data-icon="caution"', "selectView('alerts')", "selectView('arrivals')",
      "x-show=\"view === 'arrivals'\"", "x-show=\"view === 'alerts'\""
    )
    expect(body.index('id="subway-sidebar"')).to be < body.index('id="subway-map"')
    expect(body).not_to include(
      '<h1>MBTA Subway', 'Red, Orange, Blue, Green B/C/D/E, and Mattapan',
      'x-model="route"', 'toggleChime', 'enableNotifications', 'filteredStations', 'visibleAlerts'
    )
  end

  it 'returns fetch times and distinct unavailable states' do
    allow(Muni::Transit).to receive(:stations).and_return('data' => [], 'fetched_at' => '2026-01-01T00:00:00Z')
    get '/api/mobility/subway/stations'
    expect(JSON.parse(last_response.body)['fetched_at']).to eq('2026-01-01T00:00:00Z')

    allow(Muni::Transit).to receive(:vehicles).and_raise(Muni::Transit::Client::Error.new('rate limited', status: 429))
    get '/api/mobility/subway/vehicles'
    expect(last_response.status).to eq(429)
    expect(JSON.parse(last_response.body)).to include('error' => 'rate limited', 'data' => [], 'fetched_at' => nil)
  end

  it 'serves predictions and alerts from the server' do
    payload = { 'data' => [], 'fetched_at' => '2026-01-01T00:00:00Z' }
    allow(Muni::Transit).to receive(:predictions).with(stop_id: 'place-harsq').and_return(payload)
    allow(Muni::Transit).to receive(:alerts).and_return(payload)
    get '/api/mobility/subway/predictions/place-harsq'
    expect(JSON.parse(last_response.body)).to eq(payload)
    get '/api/mobility/subway/alerts'
    expect(JSON.parse(last_response.body)).to eq(payload)
  end
end
