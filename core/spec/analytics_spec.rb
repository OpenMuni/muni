require 'spec_helper'

RSpec.describe Muni::Analytics do
  before do
    Muni::Hall.load_all!
    Muni::Store.ensure_tables!
  end

  it 'computes percentiles with interpolation' do
    expect(Muni::Analytics::Support.percentile([10, 20, 30], 50)).to eq(20)
    expect(Muni::Analytics::Support.percentile([10, 20], 50)).to eq(15)
  end

  it 'predicts 311 resolution time with historical bucket fallback and ranges' do
    now = Time.utc(2026, 6, 16, 12)
    seed_resolution_samples(now)

    model = Muni::Analytics::ServiceRequestResolution.train(hall: 'cambridge', now: now)
    prediction = Muni::Analytics::ServiceRequestResolution.predict(
      model,
      case_type: 'Pothole', department: 'DPW', neighborhood: 'Area 4', opened_at: now
    )

    expect(prediction[:status]).to eq('ready')
    expect(prediction[:basis]).to eq('case type, department, neighborhood')
    expect(prediction[:predicted_days]).to eq(2.0)
    expect(prediction[:range_days][:low]).to be < prediction[:range_days][:high]
    expect(prediction[:sample_size]).to eq(3)
  end

  it 'uses permit valuation buckets for processing estimates' do
    now = Time.utc(2026, 6, 16, 12)
    [2, 4, 6].each do |days|
      upsert_permit("permit/#{days}",
                    permit_type:        'Building',
                    property_use:       'Residential',
                    declared_valuation: 75_000,
                    applied_at:         now - (days * 86_400),
                    issued_at:          now)
    end

    model = Muni::Analytics::PermitProcessing.train(hall: 'cambridge', now: now)
    prediction = Muni::Analytics::PermitProcessing.predict(
      model,
      permit_type: 'Building', property_use: 'Residential', declared_valuation: 100_000
    )

    expect(prediction[:status]).to eq('ready')
    expect(prediction[:basis]).to eq('permit type, property use, valuation bucket')
    expect(prediction[:predicted_days]).to eq(4.0)
  end

  it 'scores crash risk by recency and vulnerable road user factors' do
    now = Time.utc(2026, 6, 16, 12)
    upsert_crash('crash/high/1',
                 location: [-71.10004, 42.37004], occurred_at: now - 86_400,
                 injury: true, cyclist: true, location_description: 'Mass Ave at Main St')
    upsert_crash('crash/high/2',
                 location: [-71.10003, 42.37003], occurred_at: now - (2 * 86_400),
                 pedestrian: true, location_description: 'Mass Ave at Main St')
    upsert_crash('crash/low/1',
                 location: [-71.1200, 42.3900], occurred_at: now - (400 * 86_400),
                 location_description: 'Garden St')

    payload = Muni::Analytics::CrashRisk.compute(hall: 'cambridge', now: now)
    top = payload['locations'].first

    expect(payload['status']).to eq('ready')
    expect(top['label']).to eq('Mass Ave at Main St')
    expect(top['score']).to eq(100)
    expect(top['factors']).to include('1 cyclist', '1 pedestrian')
  end

  it 'detects 311 case-type volume anomalies against weekly baselines' do
    latest = Time.utc(2026, 6, 16, 12)
    seed_anomaly_samples(latest)

    payload = Muni::Analytics::ServiceRequestAnomalies.compute(hall: 'cambridge', now: latest)
    anomaly = payload['anomalies'].first

    expect(payload['status']).to eq('ready')
    expect(anomaly['case_type']).to eq('Pothole')
    expect(anomaly['current_count']).to eq(7)
    expect(anomaly['ratio']).to be >= 2.0
  end

  it 'scores mixed safety hotspots across crime, dispatch, and recent crashes' do
    now = Time.utc(2026, 6, 16, 12)
    upsert_crime_report('crime/hotspot/1', location: [-71.10004, 42.37004], reported_at: now - 3600)
    upsert_dispatch_call('dispatch/hotspot/1', location: [-71.10003, 42.37003], received_at: now - 1800)
    upsert_cpd_crash('cpd/hotspot/1', location: [-71.10002, 42.37002], occurred_at: now - 900)

    payload = Muni::Analytics::SafetyHotspots.compute(hall: 'cambridge', now: now)
    top = payload['locations'].first

    expect(payload['status']).to eq('ready')
    expect(top['score']).to eq(100)
    expect(top['count']).to eq(3)
  end

  it 'detects safety anomalies against rolling baselines' do
    latest = Time.utc(2026, 6, 16, 12)
    5.times do |week|
      upsert_dispatch_call("dispatch/baseline/#{week}",
                           incident_type: 'ODD TEST TYPE',
                           received_at:   latest - ((week + 2) * 7 * 86_400))
    end
    4.times do |index|
      upsert_dispatch_call("dispatch/current/#{index}",
                           incident_type: 'ODD TEST TYPE',
                           received_at:   latest - (index * 3600))
    end

    payload = Muni::Analytics::SafetyAnomalies.compute(hall: 'cambridge', now: latest)
    anomaly = payload['anomalies'].find { |row| row['label'] == 'ODD TEST TYPE' }

    expect(payload['status']).to eq('ready')
    expect(anomaly['current_count']).to eq(4)
    expect(anomaly['ratio']).to be >= 2.0
  end

  it 'detects police-log publication spikes separately from incident activity' do
    latest = Time.utc(2026, 6, 16, 12)
    seed_police_publication_spike(latest)

    payload = Muni::Analytics::PoliceLogAnomalies.compute(hall: 'cambridge', now: latest)
    signal = Muni::Dashboard.civic_signals(
      { police_log_anomalies: payload, safety_anomalies: ready_empty_safety_anomalies(latest) },
      {}
    ).find { |entry| entry[:id] == 'police_log_volume_anomalies' }

    expect(payload['incident_anomalies']).to be_empty
    expect(payload['publication_anomalies'].first).to include('time_basis' => 'reported_at')
    expect(signal).to include(
      status:       'watch',
      metric_label: 'published',
      headline:     'Police log publication volume'
    )
    expect(signal[:detail]).to include('source catch-up')
    expect(Muni::Dashboard.civic_signals(
      { police_log_anomalies: payload, safety_anomalies: ready_empty_safety_anomalies(latest) },
      {}
    ).map { |entry| entry[:id] }).not_to include('safety_anomalies')
  end

  it 'detects police-log occurrence spikes as incident activity' do
    latest = Time.utc(2026, 6, 16, 12)
    seed_police_incident_spike(latest)

    payload = Muni::Analytics::PoliceLogAnomalies.compute(hall: 'cambridge', now: latest)
    signal = Muni::Dashboard.civic_signals({ police_log_anomalies: payload }, {})
                            .find { |entry| entry[:id] == 'police_log_volume_anomalies' }

    expect(payload['incident_anomalies'].first).to include(
      'label'      => 'ODD POLICE TYPE',
      'time_basis' => 'occurred_at'
    )
    expect(signal).to include(
      status:       'watch',
      metric_label: 'incidents',
      headline:     'ODD POLICE TYPE'
    )
    expect(signal[:detail]).to include('occurrence date')
  end

  it 'prioritizes police-log publication wording when source catch-up overlaps incidents' do
    latest = Time.utc(2026, 6, 16, 12)
    seed_police_publication_spike(latest)
    seed_police_incident_spike(latest)

    payload = Muni::Analytics::PoliceLogAnomalies.compute(hall: 'cambridge', now: latest)
    signal = Muni::Dashboard.civic_signals({ police_log_anomalies: payload }, {})
                            .find { |entry| entry[:id] == 'police_log_volume_anomalies' }

    expect(payload['incident_anomalies']).not_to be_empty
    expect(payload['publication_anomalies']).not_to be_empty
    expect(signal).to include(
      metric_label: 'published',
      headline:     'Police log publication volume'
    )
    expect(signal[:detail]).to include('source catch-up')
  end

  it 'normalizes crash risk by matched exposure counts' do
    now = Time.utc(2026, 6, 16, 12)
    upsert_crash('crash/exposure/1', location: nil, location_description: 'Mass Ave and Main St',
                                     occurred_at: now - 3600)
    upsert_traffic_volume('traffic/exposure/1', intersection: 'Mass Ave and Main St', count: 1_000,
                                                observed_at: now - 7200)

    payload = Muni::Analytics::CrashExposureRisk.compute(hall: 'cambridge', now: now)
    top = payload['locations'].first

    expect(payload['status']).to eq('ready')
    expect(top['crash_count']).to eq(1)
    expect(top['exposure_count']).to eq(1000)
    expect(top['risk_per_10k']).to eq(10.0)
  end

  it 'generates structured city digest cards without an AI client' do
    now = Time.utc(2026, 6, 16, 12)
    seed_digest_source_item(now)
    log_digest_source_success(now)

    payload = Muni::Analytics::CivicDigest.compute(
      hall:   'cambridge',
      now:    now,
      client: digest_spec_client(configured: false)
    )

    expect(payload['status']).to eq('ready')
    expect(payload['schema_version']).to eq(2)
    expect(payload['title']).to eq('Digest')
    expect(payload).not_to have_key('body')
    expect(payload['cards'].first).to include('id', 'title', 'summary', 'metric', 'visual', 'href')
    expect(payload['cards'].first).to include('source_type' => 'official_record',
                                              'section_key' => 'city_today')
    expect(payload['cards'].first['sources'].first).to include('name' => 'Official City News')
    expect(payload['cards'].first['visual']['type']).to eq('source_badge')
    expect(payload['sections'].map { |section| section['key'] }).to include('city_today')
    expect_city_news_freshness(payload)
  end

  it 'ignores legacy cached digest cards at the public boundary' do
    now = Time.now.utc
    Muni::Store.upsert_analytics_result(
      hall:             'cambridge',
      kind:             Muni::Analytics::CIVIC_DIGEST,
      key:              Muni::Analytics::DEFAULT_KEY,
      payload:          { 'title' => 'City Digest', 'body' => '# old', 'cards' => [{ 'id' => 'legacy' }] },
      generated_at:     now,
      source_row_count: 1,
      source_max_at:    now
    )

    payload = described_class.digest(hall: 'cambridge')

    expect(payload['status']).to eq('warming')
    expect(payload['title']).to eq('Digest')
    expect(payload['cards']).to eq([])
    expect(payload).not_to have_key('body')
  end

  it 'recomputes from source facts instead of serving legacy cached metrics' do
    now = Time.now.utc
    seed_digest_source_item(now)
    Muni::Store.upsert_analytics_result(
      hall:             'cambridge',
      kind:             Muni::Analytics::CIVIC_DIGEST,
      key:              Muni::Analytics::DEFAULT_KEY,
      payload:          { 'title' => 'City Digest', 'cards' => [{ 'id' => '311-activity' }] },
      generated_at:     now,
      source_row_count: 1,
      source_max_at:    now
    )

    payload = described_class.digest(hall: 'cambridge')

    expect(payload['status']).to eq('ready')
    expect(payload['cards'].first).to include('id' => 'source-news/digest')
    expect(payload['cards'].map { |card| card['id'] }).not_to include('311-activity')
  end

  it 'merges valid JSON-only AI copy into deterministic digest cards' do
    now = Time.utc(2026, 6, 16, 12)
    seed_digest_source_item(now)
    authored = {
      cards:     [{
        id:          'source-news/digest',
        title:       'Edited City Notice',
        summary:     'A concise edited summary from the model.',
        source_note: 'Edited source note.'
      }],
      footnotes: ['Use official records for final decisions.']
    }
    client = digest_spec_client(JSON.dump(authored))

    payload = Muni::Analytics::CivicDigest.compute(hall: 'cambridge', now: now, client: client)
    card = payload['cards'].find { |entry| entry['id'] == 'source-news/digest' }

    expect(card['title']).to eq('Edited City Notice')
    expect(card['summary']).to eq('A concise edited summary from the model.')
    expect(card['metric']['value']).not_to be_empty
    expect(payload['footnotes']).to include('Use official records for final decisions.')
  end

  it 'falls back to deterministic digest copy when AI output is malformed' do
    now = Time.utc(2026, 6, 16, 12)
    seed_digest_source_item(now)

    payload = Muni::Analytics::CivicDigest.compute(
      hall:   'cambridge',
      now:    now,
      client: digest_spec_client('# not json **markdown**')
    )

    expect(payload['status']).to eq('ready')
    expect(payload['cards'].first['title']).not_to include('#')
    expect(payload['cards'].first['summary']).not_to include('**')
  end

  it 'uses source facts without adding metric fallback cards' do
    now = Time.utc(2026, 6, 16, 12)
    seed_digest_records(now)
    seed_digest_source_item(now)
    described_class.compute!(hall: 'cambridge', now: now)

    payload = Muni::Analytics::CivicDigest.compute(
      hall:   'cambridge',
      now:    now,
      client: digest_spec_client(configured: false)
    )

    expect(payload['cards'].first['id']).to eq('source-news/digest')
    expect(payload['cards'].map { |card| card['id'] }).not_to include('311-activity',
                                                                      'safety-activity',
                                                                      'crash-risk',
                                                                      'data-signal-crash_risk_hotspots')
  end

  it 'warms instead of showing metric cards when source facts are empty' do
    now = Time.utc(2026, 6, 16, 12)
    seed_digest_records(now)
    described_class.compute!(hall: 'cambridge', now: now)

    payload = Muni::Analytics::CivicDigest.compute(
      hall:   'cambridge',
      now:    now,
      client: digest_spec_client(configured: false)
    )

    expect(payload['status']).to eq('warming')
    expect(payload['cards']).to eq([])
    expect(payload['footnotes']).to include('Digest is warming from public Cambridge sources.')
  end

  it 'excludes legacy digest prose from the digest source payload' do
    now = Time.utc(2026, 6, 16, 12)
    seed_digest_records(now)
    seed_digest_source_item(now)
    Muni::Store.upsert_analytics_result(
      hall:             'cambridge',
      kind:             Muni::Analytics::CIVIC_DIGEST,
      key:              Muni::Analytics::DEFAULT_KEY,
      payload:          { 'status' => 'ready', 'body' => '# old markdown digest' },
      generated_at:     now,
      source_row_count: 1,
      source_max_at:    now
    )

    context = Muni::Analytics::CivicDigest.source_payload(hall: 'cambridge', now: now)

    expect(JSON.generate(context)).not_to include('old markdown digest')
    expect(context['analytics']).not_to have_key(:civic_digest)
    expect(context['analytics']).not_to have_key('civic_digest')
    expect(context['source_items'].first['title']).to eq('Cooling centers open today')
  end

  def seed_resolution_samples(now)
    [1, 2, 3].each do |days|
      upsert_service_request("sr/pothole/#{days}",
                             case_type:    'Pothole',
                             department:   'DPW',
                             neighborhood: 'Area 4',
                             opened_at:    now - (days * 86_400),
                             closed_at:    now)
    end
    upsert_service_request('sr/tree/10', case_type: 'Tree', department: 'Urban Forestry',
                                          opened_at: now - (10 * 86_400), closed_at: now)
  end

  def seed_anomaly_samples(latest)
    6.times do |week|
      week_start = latest - ((week + 2) * 7 * 86_400)
      2.times do |index|
        upsert_service_request("sr/baseline/#{week}/#{index}", opened_at: week_start + (index * 3600))
      end
    end
    7.times { |index| upsert_service_request("sr/current/#{index}", opened_at: latest - (index * 3600)) }
  end

  def seed_police_publication_spike(latest)
    5.times do |week|
      upsert_police_log("police/reported/baseline/#{week}",
                        crime_subcategory: 'ODD POLICE TYPE',
                        occurred_at:       latest - (60 * 86_400) - (week * 86_400),
                        reported_at:       latest - ((week + 2) * 7 * 86_400))
    end
    5.times do |index|
      upsert_police_log("police/reported/current/#{index}",
                        crime_subcategory: 'ODD POLICE TYPE',
                        occurred_at:       latest - (45 * 86_400) - (index * 86_400),
                        reported_at:       latest - (index * 3600))
    end
  end

  def seed_police_incident_spike(latest)
    5.times do |week|
      upsert_police_log("police/occurred/baseline/#{week}",
                        crime_subcategory: 'ODD POLICE TYPE',
                        occurred_at:       latest - ((week + 2) * 7 * 86_400),
                        reported_at:       latest - ((week + 2) * 7 * 86_400))
    end
    5.times do |index|
      upsert_police_log("police/occurred/current/#{index}",
                        crime_subcategory: 'ODD POLICE TYPE',
                        occurred_at:       latest - (index * 3600),
                        reported_at:       latest - (45 * 86_400) - (index * 86_400))
    end
  end

  def ready_empty_safety_anomalies(now)
    {
      status:        'ready',
      generated_at:  now.iso8601,
      source_max_at: now.iso8601,
      window_days:   7,
      anomalies:     []
    }
  end

  def digest_spec_client(text = '', configured: true)
    captured_messages = []
    Object.new.tap do |client|
      client.define_singleton_method(:messages) { captured_messages }
      client.define_singleton_method(:configured?) { configured }
      client.define_singleton_method(:stream) do |messages:, **, &block|
        captured_messages.replace(messages)
        block.call(type: 'text_delta', text: text)
      end
    end
  end

  def seed_digest_records(now)
    upsert_service_request('sr/digest/closed', status: 'Closed', opened_at: now - (2 * 86_400),
                                               closed_at: now - 86_400)
    upsert_service_request('sr/digest/open', status: 'Open', opened_at: now - 3600)
    upsert_permit('permit/digest', issued_at: now - 3600, applied_at: now - (3 * 86_400))
    upsert_crash('crash/digest', injury: true, cyclist: true, location_description: 'Mass Ave at Main St',
                                 occurred_at: now - 3600)
    upsert_crime_report('crime/digest', reported_at: now - 3600)
    upsert_dispatch_call('dispatch/digest', received_at: now - 1800)
    upsert_cpd_crash('cpd/digest', occurred_at: now - 1200)
    upsert_traffic_volume('traffic/digest', observed_at: now - 900)
  end

  def seed_digest_source_item(now)
    Muni::Store.upsert(Muni::Records::DigestItem.new(
                         external_id:  'news/digest',
                         hall:         'cambridge',
                         source_slug:  'cambridge/city_news',
                         source_name:  'Official City News',
                         source_type:  'official_record',
                         item_type:    'announcement',
                         section_hint: 'today_in_cambridge',
                         title:        'Cooling centers open today',
                         summary:      'The City opened cooling centers during the heat advisory.',
                         category:     'services',
                         url:          'https://www.cambridgema.gov/news/cooling',
                         published_at: now,
                         fetched_at:   now,
                         tags:         %w[weather services],
                         confidence:   0.95,
                         dedupe_key:   'cooling-centers'
                       ))
  end

  def log_digest_source_success(now)
    Muni::Store.log_beat_run(
      slug:       'cambridge/city_news',
      started_at: now - 60,
      ended_at:   now - 55,
      error:      nil
    )
    Muni::Store.bump_seen('cambridge/city_news', now - 55)
  end

  def expect_city_news_freshness(payload)
    expect(payload.dig('source_freshness', 'cambridge/city_news')).to include(
      'cadence'         => '6h',
      'last_success_at' => '2026-06-16T11:59:05Z',
      'status'          => 'ready'
    )
  end

  def upsert_service_request(external_id, attrs = {})
    values = {
      external_id:  external_id,
      hall:         'cambridge',
      case_type:    'Pothole',
      status:       'Closed',
      department:   'DPW',
      neighborhood: 'Area 4',
      description:  'large pothole on street',
      opened_at:    Time.utc(2026, 6, 1),
      closed_at:    nil,
      source_url:   'https://example.com'
    }.merge(attrs)
    Muni::Store.upsert(Muni::Records::ServiceRequest.new(**values))
  end

  def upsert_permit(external_id, attrs = {})
    values = {
      external_id:        external_id,
      hall:               'cambridge',
      permit_type:        'Building',
      status:             'Issued',
      declared_valuation: 10_000,
      applied_at:         Time.utc(2026, 6, 1),
      issued_at:          Time.utc(2026, 6, 2),
      source_url:         'https://example.com'
    }.merge(attrs)
    Muni::Store.upsert(Muni::Records::BuildingPermit.new(**values))
  end

  def upsert_crash(external_id, attrs = {})
    values = {
      external_id:          external_id,
      hall:                 'cambridge',
      crash_type:           'Crash',
      injury:               false,
      fatal:                false,
      cyclist:              false,
      pedestrian:           false,
      location_description: 'Cambridge',
      occurred_at:          Time.utc(2026, 6, 1),
      source_url:           'https://example.com'
    }.merge(attrs)
    Muni::Store.upsert(Muni::Records::Crash.new(**values))
  end

  def upsert_crime_report(external_id, attrs = {})
    values = {
      external_id:          external_id,
      hall:                 'cambridge',
      crime_category:       'Larceny',
      neighborhood:         'Area 4',
      location_description: 'Mass Ave',
      reported_at:          Time.utc(2026, 6, 1),
      source_url:           'https://example.com'
    }.merge(attrs)
    Muni::Store.upsert(Muni::Records::CrimeReport.new(**values))
  end

  def upsert_police_log(external_id, attrs = {})
    values = {
      external_id:       external_id,
      hall:              'cambridge',
      crime_category:    'INCIDENT',
      crime_subcategory: 'TRAFFIC',
      occurred_at:       Time.utc(2026, 6, 1),
      reported_at:       Time.utc(2026, 6, 1),
      source_url:        'https://example.com'
    }.merge(attrs)
    Muni::Store.upsert(Muni::Records::PoliceLogEntry.new(**values))
  end

  def upsert_dispatch_call(external_id, attrs = {})
    values = {
      external_id:    external_id,
      hall:           'cambridge',
      agency:         'Fire',
      incident_type:  'BOX ALARM',
      incident_group: 'FIRE ALARM',
      neighborhood:   'Area 4',
      received_at:    Time.utc(2026, 6, 1),
      source_url:     'https://example.com'
    }.merge(attrs)
    Muni::Store.upsert(Muni::Records::DispatchCall.new(**values))
  end

  def upsert_cpd_crash(external_id, attrs = {})
    values = {
      external_id:          external_id,
      hall:                 'cambridge',
      location_description: 'Mass Ave and Main St',
      neighborhood:         'Area 4',
      injury:               true,
      occurred_at:          Time.utc(2026, 6, 1),
      source_url:           'https://example.com'
    }.merge(attrs)
    Muni::Store.upsert(Muni::Records::CpdCrash.new(**values))
  end

  def upsert_traffic_volume(external_id, attrs = {})
    values = {
      external_id:     external_id,
      hall:            'cambridge',
      intersection_id: 'intersection-1',
      intersection:    'Mass Ave and Main St',
      vehicle_class:   'Light',
      count:           1000,
      observed_at:     Time.utc(2026, 6, 1),
      source_url:      'https://example.com'
    }.merge(attrs)
    Muni::Store.upsert(Muni::Records::TrafficVolumeDaily.new(**values))
  end
end
