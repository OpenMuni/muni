require 'spec_helper'
require 'timeout'

RSpec.describe 'Public endpoint security' do
  def app = Muni::Www::App

  let(:private_error) { 'upstream failed: token=synthetic-private-marker /private/internal/file' }

  before { Muni::Store.ensure_tables! }

  def seed_failure
    Muni::Store.log_beat_run(slug: 'cambridge/service_requests', started_at: Time.now.utc,
                             ended_at: Time.now.utc, error: private_error)
  end

  it 'redacts health and dashboard failures while retaining private diagnostics in storage' do
    seed_failure
    %w[/healthz /api/dashboard?hall=cambridge /api/status?hall=cambridge].each do |path|
      get path
      expect(last_response.status).to eq(200)
      expect(last_response.body).not_to include(private_error, 'synthetic-private-marker')
      expect(last_response.body).to include('latest collection failed')
    end
    expect(Muni::Store.latest_beat_run('cambridge/service_requests')[:error]).to eq(private_error)
  end

  it 'does not expose exceptions from readiness checks' do
    allow(Muni::Store).to receive(:counts_by_source).and_raise(StandardError, private_error)
    get '/readyz'
    expect(last_response.status).to eq(503)
    expect(JSON.parse(last_response.body)['error']).to eq('readiness check failed')
    expect(last_response.body).not_to include('synthetic-private-marker')
  end

  it 'redacts water coverage and historical signal payloads' do
    allow(Muni::Water).to receive(:enabled?).and_return(true)
    seed_water_failure
    ['/api/water/charles/coverage', '/api/water/charles/signals',
     '/api/water/charles/signals?versions=1', '/api/status?hall=cambridge'].each do |path|
      get path
      expect(last_response.status).to eq(200)
      expect(last_response.body).not_to include('synthetic-private-marker')
      expect(last_response.body).to include('latest collection failed')
    end
  end

  it 'completes idle event responses without waiting for a source update' do
    Timeout.timeout(2) do
      10.times do
        get '/stream/cambridge/service_requests'
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("retry: 15000\n\n", 'id: ')
      end
      get '/healthz'
      expect(last_response.status).to eq(200)
    end
  end

  it 'bounds reconnection queries and tolerates malformed event IDs' do
    %w[invalid 1900-01-01T00:00:00Z 2999-01-01T00:00:00Z].each do |cursor|
      get '/stream/category/service_requests', {}, 'HTTP_LAST_EVENT_ID' => cursor
      expect(last_response.status).to eq(200)
      expect(last_response.headers['content-type']).to include('text/event-stream')
    end
  end

  def seed_water_failure
    slug = "#{Muni::Water::PREFIX}epa_buoy"
    Muni::Water::Storage.db[:water_runs].insert(source_slug: slug, started_at: Time.now.utc,
                                                status: 'failed', error: private_error)
    signal = { id: 'historical-failure', signal_key: "collection/#{slug}", kind: 'collection_interruption',
               status: 'active', generated_at: Time.now.utc, payload: JSON.dump(error: private_error) }
    %i[water_signals water_signal_versions].each { |table| Muni::Water::Storage.db[table].insert(signal) }
  end
end
