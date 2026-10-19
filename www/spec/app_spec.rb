require 'spec_helper'

RSpec.describe Muni::Www::App do
  def app
    described_class
  end

  before { Muni::Store.ensure_tables! }

  def rail_app_titles(body)
    body.scan(/title="(Digest|Trends|Meetings|Train)"/).flatten.first(4)
  end

  def upsert_stale_service_request(now)
    Muni::Store.upsert(
      Muni::Records::ServiceRequest.new(
        external_id: 'sr/stale-data',
        hall:        'cambridge',
        case_type:   'Pothole',
        status:      'Open',
        opened_at:   now - (10 * 86_400),
        updated_at:  now - (10 * 86_400),
        source_url:  'https://example.com'
      )
    )
  end

  def upsert_stream_digest_item(source_slug, external_id, event_start_at)
    Muni::Store.upsert(Muni::Records::DigestItem.new(
                         external_id:    external_id,
                         hall:           'cambridge',
                         source_slug:    source_slug,
                         source_name:    source_slug.split('/').last.tr('_', ' '),
                         source_type:    'event_listing',
                         item_type:      'event',
                         title:          external_id,
                         event_start_at: event_start_at,
                         fetched_at:     event_start_at
                       ))
  end

  def log_noisy_service_request_beats(now, count: 201)
    count.times do |i|
      Muni::Store.log_beat_run(
        slug:       'cambridge/service_requests',
        started_at: now - i,
        ended_at:   now - i,
        rows_in:    1,
        error:      nil
      )
    end
  end

  it 'serves the HTML shell at /' do
    get '/'
    expect(last_response).to be_ok
    expect(last_response.body).to include('OpenMuni', '/icons/openmuni-logo.png')
    expect(last_response.body).not_to include('/auth/', '/ask?')
  end

  it 'does not expose connected identity or submission endpoints' do
    %w[/login /ask /ops /api/auth/session /api/halls/cambridge/report-services].each do |path|
      get path
      expect(last_response.status).to eq(404), path
    end
  end

  it 'renders a compact municipality selector and switches through the Hall query' do
    get '/?hall=cambridge'
    expect(last_response).to be_ok
    expect(last_response.body).to include(
      'aria-label="Municipality"',
      'data-selected="Cambridge, MA"',
      'value="boston"',
      'value="cambridge" selected'
    )

    get '/?hall=boston'
    expect(last_response).to be_ok
    expect(last_response.body).to include(
      'data-selected="Boston, MA"',
      'value="boston" selected',
      'value="cambridge"'
    )
  end

  it 'resolves Cambridge from the city subdomain for public APIs' do
    header 'Host', 'cambridge.muni.fyi'
    get '/api/categories'
    header 'Host', 'example.org'

    expect(last_response).to be_ok
    slugs = JSON.parse(last_response.body).map { |row| row['slug'] }
    expect(slugs).to include('service_requests')
  end

  it 'serves Boston from query parameters and its city subdomain' do
    get '/?hall=boston'
    expect(last_response).to be_ok
    expect(last_response.body).to include('Boston, MA')
    expect(last_response.body).not_to include('title="Meetings"')

    header 'Host', 'boston.muni.fyi'
    get '/api/categories'
    header 'Host', 'example.org'
    expect(last_response).to be_ok
    slugs = JSON.parse(last_response.body).map { |row| row['slug'] }
    expect(slugs).to include('service_requests', 'crime_reports', 'crashes', 'events')
    expect(slugs).not_to include('police', 'dispatch_calls')
  end

  it 'returns 404 for explicit invalid Hall query parameters and subdomains' do
    get '/?hall=not-a-city'
    expect(last_response.status).to eq(404)

    header 'Host', 'not-a-city.muni.fyi'
    get '/api/categories'
    header 'Host', 'example.org'
    expect(last_response.status).to eq(404)
  end

  it 'keeps configured non-public Halls out of discovery and direct routes' do
    previous = ENV.fetch('MUNI_PUBLIC_HALLS', nil)
    ENV['MUNI_PUBLIC_HALLS'] = 'cambridge'

    get '/api/halls'
    expect(JSON.parse(last_response.body).map { |hall| hall['slug'] }).to eq(['cambridge'])
    get '/?hall=boston'
    expect(last_response.status).to eq(404)
  ensure
    previous ? ENV['MUNI_PUBLIC_HALLS'] = previous : ENV.delete('MUNI_PUBLIC_HALLS')
  end

  it 'publishes Boston capabilities and hides unavailable mobile apps' do
    get '/api/halls'
    halls = JSON.parse(last_response.body)
    boston = halls.find { |hall| hall['slug'] == 'boston' }
    expect(boston['capabilities']).to eq('report' => false, 'meetings' => false, 'read' => true)

    get '/api/mobile/bootstrap?hall=boston&category=service_requests'
    payload = JSON.parse(last_response.body)
    expect(payload['capabilities']).to eq('report' => false, 'meetings' => false, 'read' => true)
    expect(payload['apps'].find { |app| app['id'] == 'calendar' }['status']).to eq('unavailable')
    expect(payload['categories'].find { |category| category['slug'] == 'events' }['empty_message'])
      .to eq('No official city events in this window.')
    expect(last_response.body).not_to include('Cambridge')
  end

  it 'serves the about page' do
    get '/about?hall=cambridge'
    expect(last_response).to be_ok
    expect(last_response.body).to include('Municipal information for every human')
    expect(last_response.body).to include('Municipal Unified Network of Information')
    expect(last_response.body).to include('accessible to all humans')
    expect(last_response.body).to include('hello@muni.fyi')
  end

  it 'serves the Digest app' do
    get '/digest?hall=cambridge'
    expect(last_response).to be_ok
    expect(last_response.body).to include('Digest')
    expect(last_response.body).to include('muniDigest')
    expect(last_response.body).to include('data-icon="newspaper"')
    expect(last_response.body).to include('Trends')
    expect(last_response.body).not_to include('City Digest')
    expect(last_response.body).not_to include('Metrics')
  end

  it 'serves dashboard and trends entry points' do
    get '/dashboard?hall=cambridge'
    expect(last_response).to be_ok
    dashboard_body = last_response.body
    expect(dashboard_body).to include('/digest?hall=cambridge', '/trends?hall=cambridge', 'Trends')
    expect(dashboard_body).not_to include('Metrics', 'civic-digest-title', 'class="civic-digest')

    get '/trends?hall=cambridge'
    expect(last_response).to be_ok
    trends_body = last_response.body
    expect(trends_body).to include('Trends', 'dashboard-grid--skeleton')
    expect(trends_body.scan('metric-panel--skeleton').count).to eq(16)
  end

  it 'uses Digest and Trends links in shell entry points' do
    get '/?hall=cambridge'
    expect(last_response.body).to include('/digest?hall=cambridge')
    expect(last_response.body).to include('/trends?hall=cambridge')
  end

  it 'keeps the app rail order stable across app pages' do
    expected = %w[Trends Digest Meetings Train]

    ['/?hall=cambridge', '/digest?hall=cambridge',
     '/trends?hall=cambridge', '/meetings?hall=cambridge'].each do |path|
      get path

      expect(last_response).to be_ok
      expect(rail_app_titles(last_response.body)).to eq(expected)
      expect(last_response.body).not_to include('/report?hall=cambridge')
      expect(last_response.body).not_to include('title="Muni"')
    end
  end

  it 'reports healthy at /healthz' do
    get '/healthz'
    expect(last_response).to be_ok
    body = JSON.parse(last_response.body)
    expect(body['ok']).to be(true)
    expect(body).to have_key('counts')
  end

  it 'serves the lightweight public status page without the app shell assets' do
    get '/status'

    expect(last_response).to be_ok
    expect(last_response.body).to include('<title>Muni Status</title>')
    expect(last_response.body).to include('status.json')
    expect(last_response.body).not_to include('/js/muni.js', 'maplibre-gl')
  end

  it 'ignores stale beat runs for removed sources in health output' do
    now = Time.utc(2026, 6, 14, 12, 0, 0)
    Muni::Store.log_beat_run(slug: 'legacy/removed_source', started_at: now,
                             ended_at: now, rows_in: 1, rows_upserted: 1)

    get '/healthz'

    body = JSON.parse(last_response.body)
    expect(body['last_beat']).to be_nil
  end

  it 'reports not ready before launch data and basemaps are seeded' do
    original_env = ENV.to_h
    Dir.mktmpdir('muni-tiles') do |dir|
      ENV['RACK_ENV'] = 'production'
      ENV['MUNI_TILES_PATH'] = dir
      ENV['MUNI_BASEMAP_MODE'] = 'pmtiles'
      ENV.delete('MUNI_MAP_STYLE')
      ENV.delete('MUNI_MAPTILER_KEY')
      ENV.delete('MUNI_MAP_TILES')

      get '/readyz'

      expect(last_response.status).to eq(503)
      body = JSON.parse(last_response.body)
      expect(body['ready']).to be(false)
      expect(body['sources'].values).to include(false)
      expect(body['beats'].values).to include(false)
      expect(body.dig('basemap', 'ready')).to be(false)
    ensure
      ENV.replace(original_env)
    end
  end

  it 'allows readiness freshness to follow each beat cadence' do
    original_env = ENV.to_h
    now = Time.now.utc
    beat_class = Muni::Registry.beat('cambridge/practical_services')
    Muni::Store.log_beat_run(
      slug:       beat_class.slug,
      started_at: now - 86_400,
      ended_at:   now - 86_400 + 60,
      rows_in:    1,
      error:      nil
    )

    ENV.delete('MUNI_READY_MAX_BEAT_AGE_SECONDS')
    ENV['MUNI_READY_BEAT_GRACE_SECONDS'] = '10800'

    readiness = described_class.new!.send(:beat_readiness)

    expect(readiness[beat_class.slug]).to be(true)
  ensure
    ENV.replace(original_env)
  end

  it 'keeps daily beat readiness visible beyond the 200 most recent beat rows' do
    original_env = ENV.to_h
    now = Time.now.utc
    daily_beat = Muni::Registry.beat('cambridge/practical_services')
    Muni::Store.log_beat_run(
      slug:       daily_beat.slug,
      started_at: now - 1_000,
      ended_at:   now - 900,
      rows_in:    1,
      error:      nil
    )
    log_noisy_service_request_beats(now)

    ENV.delete('MUNI_READY_MAX_BEAT_AGE_SECONDS')
    ENV['MUNI_READY_BEAT_GRACE_SECONDS'] = '10800'

    readiness = described_class.new!.send(:beat_readiness)

    expect(readiness[daily_beat.slug]).to be(true)
  ensure
    ENV.replace(original_env)
  end

  it 'scopes SSE stream rows for shared digest sources' do
    cursor = Time.utc(2026, 6, 18, 12)
    upsert_stream_digest_item('cambridge/city_calendar', 'calendar/stream', cursor + 60)
    upsert_stream_digest_item('cambridge/tourism_events', 'tourism/stream', cursor + 120)

    rows = Muni::Www::Routes::Stream.new!.send(:stream_rows, ['cambridge/city_calendar'], 'cambridge', cursor)

    expect(rows.map(&:external_id)).to eq(['calendar/stream'])
  end

  it 'marks 311 source data stale even when the collector beat is fresh' do
    original_env = ENV.to_h
    now = Time.utc(2026, 6, 25, 12, 0, 0)
    upsert_stale_service_request(now)
    Muni::Store.log_beat_run(
      slug:       'cambridge/service_requests',
      started_at: now - 60,
      ended_at:   now,
      rows_in:    1,
      error:      nil
    )
    ENV['MUNI_READY_MAX_SOURCE_LAG_SECONDS'] = (2 * 86_400).to_s

    readiness = described_class.new!.send(:source_data_readiness, now)

    expect(readiness['cambridge/service_requests']).to be(false)
  ensure
    ENV.replace(original_env)
  end

  it 'persists hall in a cookie and reuses it on the next visit' do
    get '/?hall=cambridge'
    expect(last_response).to be_ok
    expect(last_response.headers['Set-Cookie']).to include('hall=cambridge')

    get '/', { 'HTTP_COOKIE' => 'hall=cambridge' }
    expect(last_response.body).to include('Cambridge, MA')
  end

  it 'defaults production basemaps to auto mode with raster fallback' do
    original_env = ENV.to_h
    Dir.mktmpdir('muni-tiles') do |dir|
      ENV['RACK_ENV'] = 'production'
      ENV['MUNI_TILES_PATH'] = dir
      ENV.delete('MUNI_BASEMAP_MODE')
      ENV.delete('MUNI_MAP_STYLE')
      ENV.delete('MUNI_MAPTILER_KEY')
      ENV.delete('MUNI_MAP_TILES')

      get '/?hall=cambridge'

      expect(last_response).to be_ok
      expect(last_response.body).to include('window.MUNI_BASEMAP_MODE = "auto"')
      expect(last_response.body).to include('window.MUNI_PMTILES_READY = false')
      expect(last_response.body).not_to include('Production basemap is not configured')
    ensure
      ENV.replace(original_env)
    end
  end

  it 'shows a production basemap error in strict PMTiles mode when missing' do
    original_env = ENV.to_h
    Dir.mktmpdir('muni-tiles') do |dir|
      ENV['RACK_ENV'] = 'production'
      ENV['MUNI_TILES_PATH'] = dir
      ENV['MUNI_BASEMAP_MODE'] = 'pmtiles'
      ENV.delete('MUNI_MAP_STYLE')
      ENV.delete('MUNI_MAPTILER_KEY')
      ENV.delete('MUNI_MAP_TILES')

      get '/?hall=cambridge'

      expect(last_response).to be_ok
      expect(last_response.body).to include('window.MUNI_BASEMAP_MODE = "pmtiles"')
      expect(last_response.body).to include('window.MUNI_PMTILES_READY = false')
      expect(last_response.body).to include('Production basemap is not configured')
    ensure
      ENV.replace(original_env)
    end
  end

  it 'marks the packaged PMTiles basemap ready when present' do
    original_env = ENV.to_h
    Dir.mktmpdir('muni-tiles') do |dir|
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, 'muni.pmtiles'), 'pmtiles')
      ENV['RACK_ENV'] = 'production'
      ENV['MUNI_TILES_PATH'] = dir
      ENV.delete('MUNI_BASEMAP_MODE')
      ENV.delete('MUNI_MAP_STYLE')
      ENV.delete('MUNI_MAPTILER_KEY')
      ENV.delete('MUNI_MAP_TILES')

      get '/?hall=cambridge'

      expect(last_response).to be_ok
      expect(last_response.body).to include('window.MUNI_BASEMAP_MODE = "auto"')
      expect(last_response.body).to include('window.MUNI_PMTILES_READY = true')
      expect(last_response.body).not_to include('Production basemap is not configured')
    ensure
      ENV.replace(original_env)
    end
  end

  it 'uses the current Protomaps browser API for the self-hosted basemap' do
    script = File.read(File.expand_path('../public/js/muni.js', __dir__))

    expect(script).to include(
      'window.basemaps?.layers',
      "basemapFlavor('light')",
      'https://protomaps.github.io/basemaps-assets/fonts/{fontstack}/{range}.pbf',
      'https://protomaps.github.io/basemaps-assets/sprites/v4/light'
    )
    expect(script).not_to include("protomapsLayers('protomaps'")
  end
end
