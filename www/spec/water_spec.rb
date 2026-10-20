require 'spec_helper'

RSpec.describe 'Charles River region and Water Quality API' do
  def app = Muni::Www::App

  before do
    Muni::Store.ensure_tables!
    allow(Muni::Water).to receive(:enabled?).and_return(true)
  end

  it 'redirects city bookmarks to the independent region while preserving view and filters' do
    %w[cambridge boston].each do |hall|
      get "/water?hall=#{hall}&view=records&days=90&source=water%2Fcharles%2Fepa_buoy"
      expect(last_response.status).to eq(302)
      uri = URI(last_response.headers['location'])
      expect(uri.path).to eq('/water/charles')
      expect(Rack::Utils.parse_query(uri.query)).to eq(
        'view' => 'records', 'days' => '90', 'source' => 'water/charles/epa_buoy'
      )
      follow_redirect!
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('<title>OpenMuni · Charles River</title>', '>Records</h1>')
    end
  end

  it 'uses river navigation independently of the municipal cookie or host' do
    set_cookie 'hall=boston'
    get '/water/charles', {}, 'HTTP_HOST' => 'cambridge.muni.fyi'
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('data-selected="Charles River"', 'aria-label="Region"', '>Charles River</h1>')
    %w[Metrics Map Records Datasets].each { |label| expect(last_response.body).to include("title=\"#{label}\"") }
    expect(last_response.body).not_to include('title="Ask"', 'title="Digest"', 'title="Meetings"', 'water-tabs')
    expect(last_response.headers['set-cookie'].to_s).not_to include('hall=charles')
    expect(Muni::Hall.find('charles')).to be_nil
    get '/water/charles?hall=boston&view=datasets'
    follow_redirect!
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('>Datasets</h1>', 'Check schedule', 'Records retained')
  end

  it 'labels the direct river page without adding a selectable river control' do
    get '/water/charles'
    expect(last_response.body).to include('<option value="" selected disabled hidden>Charles River</option>')
    expect(last_response.body).not_to include('value="charles"')
    expect(last_response.body).to match(/title="Map".*?data-icon="map"/m)
  end

  it 'keeps Charles River controls out of municipal navigation' do
    %w[cambridge boston].each do |hall|
      get "/?hall=#{hall}"
      expect(last_response.status).to eq(200)
      expect(last_response.body).not_to include('value="charles"', 'href="/water/charles"', 'title="Water"')
      expect(last_response.body).not_to include('value="subway"')
      expect(last_response.body).not_to include('href="/water/charles">Charles River ↗</a>')
      expect(last_response.body).not_to include('aria-label="Water Quality"')
    end
    get '/?hall=cambridge'
    expect(last_response.body).to include('title="Digest"', 'title="Meetings"')
  end

  it 'shares read-only evidence between municipal API clients and the river region' do
    # Compare the same reporting window even when the requests cross a second boundary.
    allow(Time).to receive(:now).and_return(Time.utc(2026, 10, 20, 20, 39, 39))
    get '/api/water/charles?hall=cambridge'
    expect(last_response.status).to eq(200)
    cambridge = JSON.parse(last_response.body)
    get '/api/water/charles?hall=boston'
    expect(last_response.status).to eq(200)
    boston = JSON.parse(last_response.body)
    expect(cambridge).to eq(boston)
    expect(boston['shared_with']).to eq(%w[cambridge boston])
  end

  it 'requires the feature flag for every entry point' do
    allow(Muni::Water).to receive(:enabled?).and_return(false)
    %w[/water?hall=cambridge /water/charles /api/water/charles].each do |url|
      get url
      expect(last_response.status).to eq(404)
    end
    get '/?hall=cambridge'
    expect(last_response.body).not_to include('href="/water/charles"', 'value="charles"')
  end

  it 'can pause public data views while keeping collection and coverage available' do
    allow(Muni::Water).to receive(:presentation_enabled?).and_return(false)
    %w[/water/charles /api/water/charles/metrics /api/water/charles/records].each do |url|
      get url
      expect(last_response.status).to eq(503)
    end
    get '/api/water/charles/coverage'
    expect(last_response.status).to eq(200)
    expect(Muni::Water.enabled?).to be(true)
    expect(Muni::Water::Catalog.definitions.size).to eq(8)
  end

  it 'reports incomplete coverage with empty results instead of an all clear' do
    get '/api/water/charles/events'
    body = JSON.parse(last_response.body)
    expect(body['records']).to eq([])
    expect(body['source_coverage'].find { |row| row['id'] == 'bwsc' }['status']).to eq('incomplete')
    expect(body['source_coverage'].find { |row| row['id'] == 'epa_buoy' }['status']).to eq('insufficient_evidence')
  end

  it 'bounds pagination and validates dates and aggregation requests' do
    %w[/api/water/charles/events?limit=9000 /api/water/charles/events?from=invalid
       /api/water/charles/series?aggregation=day /api/water/charles/series?aggregation=magic].each do |url|
      get url
      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body)).to have_key('error')
    end
  end

  it 'serves bounded charts and filters record kinds without mixing predictions into measurements' do
    db = Muni::Water::Storage.db
    %w[sensor gauge prediction].each do |kind|
      db[:water_evidence].insert(external_id: kind, kind: kind, observed_at: Time.now.utc,
                                 source_slug: 'water/charles/epa_buoy', payload: '{}')
    end
    get '/api/water/charles/records?kinds=sensor,gauge&limit=1'
    body = JSON.parse(last_response.body)
    expect(body['total']).to eq(2)
    expect(body['next_offset']).to eq(1)
    get '/api/water/charles/trends?source=unknown'
    expect(last_response.status).to eq(400)
    get '/api/water/charles/trends?source=water/charles/wqp&from=2026-10-01&to=2026-10-03'
    expect(JSON.parse(last_response.body)['series'].first['points'].length).to eq(2)
  end

  it 'exports normalized provenance and qualifiers as CSV with pagination metadata' do
    get '/api/water/charles/export.csv?limit=1'
    expect(last_response.status).to eq(200)
    expect(last_response.headers['content-type']).to include('text/csv')
    expect(CSV.parse(last_response.body).first).to include('source_url', 'original_timezone', 'payload', 'kind')
    expect(last_response.headers['x-total-count']).to eq('0')
  end

  it 'registers a single shared set of optional jobs without changing municipal readiness' do
    Muni::Water.register!
    Muni::Water.register!
    beats = Muni::Registry.beats.keys.grep(%r{^water/charles/})
    expect(beats.length).to eq(8)
    source = Muni::Registry.source('water/charles/epa_buoy')
    expect(source.applicable_to_hall?('cambridge')).to be(true)
    expect(source.applicable_to_hall?('boston')).to be(true)
    readiness = Object.new.extend(Muni::Www::ReadinessHelpers)
    expect(readiness.beat_readiness.keys).not_to include(*beats)
    expect(readiness.source_readiness({}).keys).not_to include(*beats)
    expect(readiness.source_readiness({})).to include('cambridge/service_requests' => false)
  ensure
    Muni::Registry.beats.keys.grep(%r{^water/}).each { |slug| Muni::Registry.deregister_beat(slug) }
    Muni::Registry.sources.keys.grep(%r{^water/}).each { |slug| Muni::Registry.deregister_source(slug) }
  end
end
