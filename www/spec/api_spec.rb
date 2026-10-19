require 'spec_helper'

RSpec.describe Muni::Www::App do
  def app
    described_class
  end

  def upsert_service_request(external_id, attrs = {})
    Muni::Store.upsert(Muni::Records::ServiceRequest.new(
                         external_id:  external_id,
                         hall:         'cambridge',
                         case_type:    'Pothole',
                         status:       'Open',
                         department:   'DPW',
                         neighborhood: 'Area 4',
                         description:  'request',
                         location:     [-71.11, 42.32],
                         opened_at:    Time.now.utc,
                         source_url:   'https://example/request',
                         **attrs
                       ))
  end

  def seed_lifecycle_service_requests(now:, location:)
    day = 24 * 60 * 60
    upsert_service_request('sr/open-old', status: 'Open', location: location,
                                          opened_at: now - (30 * day), updated_at: now - (30 * day),
                                          collected_at: now)
    upsert_service_request('sr/closed-recent', status: 'Closed', location: location,
                                               opened_at: now - (20 * day), closed_at: now - (2 * day),
                                               updated_at: now - (2 * day), collected_at: now)
    upsert_service_request('sr/closed-old', status: 'Closed', location: location,
                                            opened_at: now - (20 * day), closed_at: now - (4 * day),
                                            updated_at: now - (4 * day), collected_at: now)
    upsert_service_request('sr/stale', status: 'Acknowledged', location: location,
                                       opened_at: now - (20 * day), updated_at: now - (15 * day),
                                       acknowledged_at: now - (15 * day), collected_at: now)
  end

  def seed_newer_closed_service_requests(count:, now:, location:)
    closed_at = now - (10 * 24 * 60 * 60)
    closed_rows = count.times.map do |index|
      {
        external_id:  "sr/newer-closed/#{index}",
        hall:         'cambridge',
        case_type:    'Pothole',
        status:       'Closed',
        department:   'DPW',
        neighborhood: 'Area 4',
        description:  'request',
        location:     JSON.generate(location),
        address:      nil,
        opened_at:    now - index,
        updated_at:   closed_at,
        closed_at:    closed_at,
        source_url:   'https://example/request',
        collected_at: now,
        last_seen_at: now
      }
    end
    Muni::Store.with_writer do
      Muni::Store.db[:service_requests].multi_insert(closed_rows)
    end
  end

  def expect_stale_lifecycle_payload(rows, now:)
    day = 24 * 60 * 60
    stale = rows.find { |row| row['external_id'] == 'sr/stale' }
    expect(stale).to include(
      'reported_at'      => (now - (20 * day)).iso8601,
      'display_status'   => 'stale',
      'lifecycle_status' => 'stale',
      'last_touched_at'  => (now - (15 * day)).iso8601,
      'map_visible'      => true
    )
  end

  def upsert_crash(external_id, attrs = {})
    Muni::Store.upsert(Muni::Records::Crash.new(
                         external_id:          external_id,
                         hall:                 'cambridge',
                         crash_type:           'Crash',
                         injury:               false,
                         fatal:                false,
                         location_description: 'Cambridge',
                         location:             [-71.11, 42.37],
                         occurred_at:          Time.now.utc,
                         source_url:           'https://example/crash',
                         **attrs
                       ))
  end

  def upsert_permit(external_id, attrs = {})
    Muni::Store.upsert(Muni::Records::BuildingPermit.new(
                         external_id:        external_id,
                         hall:               'cambridge',
                         permit_type:        'Building: Alteration and Addition',
                         status:             'Active',
                         description:        'Permit',
                         address:            '795 Massachusetts Ave, Cambridge, MA',
                         location:           [-71.11, 42.37],
                         declared_valuation: 10_000,
                         issued_at:          Time.now.utc,
                         source_url:         'https://example/permit',
                         **attrs
                       ))
  end

  def upsert_new_construction(external_id, attrs = {})
    Muni::Store.upsert(Muni::Records::NewConstructionPermit.new(
                         external_id:          external_id,
                         hall:                 'cambridge',
                         status:               'Issued',
                         address:              '1350 Massachusetts Ave, Cambridge, MA',
                         location:             [-71.12, 42.37],
                         proposed_use:         'Mixed use',
                         construction_type:    'New building',
                         dwelling_units:       12,
                         gross_square_footage: 24_000,
                         declared_valuation:   1_200_000,
                         description:          'New construction',
                         issued_at:            Time.now.utc,
                         source_url:           'https://example/new-construction',
                         **attrs
                       ))
  end

  def upsert_development_project(external_id, attrs = {})
    Muni::Store.upsert(Muni::Records::DevelopmentProject.new(
                         external_id:       external_id,
                         hall:              'cambridge',
                         name:              'Central Square development',
                         status:            'Active',
                         address:           '10 Green St, Cambridge, MA',
                         location:          [-71.10, 42.36],
                         primary_use:       'Housing',
                         project_type:      'Major development',
                         residential_units: 48,
                         developer:         'Example Developer',
                         neighborhood:      'The Port',
                         collected_at:      Time.now.utc,
                         last_seen_at:      Time.now.utc,
                         source_url:        'https://example/development',
                         **attrs
                       ))
  end

  def upsert_zoning_appeal(external_id, attrs = {})
    Muni::Store.upsert(Muni::Records::ZoningAppeal.new(
                         external_id:              external_id,
                         hall:                     'cambridge',
                         status:                   'Complete',
                         address:                  '795 Massachusetts Ave, Cambridge, MA',
                         location:                 [-71.11, 42.37],
                         current_use:              'Commercial',
                         proposed_use:             'Commercial',
                         zoning_district:          'Business A',
                         relief:                   'Special permit relief',
                         dwelling_units_requested: 0,
                         applied_at:               Time.now.utc,
                         source_url:               'https://example/zoning',
                         **attrs
                       ))
  end

  def upsert_police_log(external_id, attrs = {})
    Muni::Store.upsert(Muni::Records::PoliceLogEntry.new(
                         external_id:       external_id,
                         hall:              'cambridge',
                         crime_category:    'INCIDENT',
                         crime_subcategory: 'TRAFFIC',
                         occurred_at:       Time.now.utc,
                         reported_at:       Time.now.utc,
                         source_url:        'https://example/police',
                         **attrs
                       ))
  end

  def upsert_crime_report(external_id, attrs = {})
    Muni::Store.upsert(Muni::Records::CrimeReport.new(
                         external_id:          external_id,
                         hall:                 'cambridge',
                         crime_category:       'Larceny',
                         reporting_area:       '802',
                         neighborhood:         'Area 4',
                         location_description: 'Mass Ave',
                         location:             [-71.10, 42.37],
                         reported_at:          Time.now.utc,
                         source_url:           'https://example/crime',
                         **attrs
                       ))
  end

  def upsert_dispatch_call(external_id, attrs = {})
    Muni::Store.upsert(Muni::Records::DispatchCall.new(
                         external_id:    external_id,
                         hall:           'cambridge',
                         agency:         'Fire',
                         incident_type:  'BOX ALARM',
                         incident_group: 'FIRE ALARM',
                         neighborhood:   'Area 4',
                         address:        '0XX ESSEX ST',
                         location:       [-71.09, 42.36],
                         received_at:    Time.now.utc,
                         source_url:     'https://example/dispatch',
                         **attrs
                       ))
  end

  def upsert_cpd_crash(external_id, attrs = {})
    Muni::Store.upsert(Muni::Records::CpdCrash.new(
                         external_id:          external_id,
                         hall:                 'cambridge',
                         location_description: 'Channing St / Mt Auburn',
                         neighborhood:         'West Cambridge',
                         motorists:            2,
                         injuries:             1,
                         injury:               true,
                         location:             [-71.12, 42.37],
                         occurred_at:          Time.now.utc,
                         source_url:           'https://example/cpd-crash',
                         **attrs
                       ))
  end

  def upsert_traffic_volume(external_id, attrs = {})
    Muni::Store.upsert(Muni::Records::TrafficVolumeDaily.new(
                         external_id:     external_id,
                         hall:            'cambridge',
                         intersection_id: 'mass-main',
                         intersection:    'Mass Ave and Main St',
                         vehicle_class:   'Car',
                         count:           1200,
                         location:        [-71.10, 42.36],
                         observed_at:     Time.now.utc,
                         source_url:      'https://example/traffic',
                         **attrs
                       ))
  end

  def upsert_bicycle_count(external_id, attrs = {})
    Muni::Store.upsert(Muni::Records::BicycleCount.new(
                         external_id:       external_id,
                         hall:              'cambridge',
                         count_location:    'Concord Ave and Garden St',
                         street:            'Concord Ave',
                         traffic_direction: 'Eastbound',
                         cyclist_location:  'Bike lane',
                         cyclist_direction: 'Eastbound',
                         movement_type:     'Through',
                         count:             42,
                         location:          [-71.12, 42.37],
                         observed_at:       Time.now.utc,
                         source_url:        'https://example/bike',
                         **attrs
                       ))
  end

  def upsert_pedestrian_count(external_id, attrs = {})
    Muni::Store.upsert(Muni::Records::PedestrianCountDaily.new(
                         external_id:  external_id,
                         hall:         'cambridge',
                         intersection: 'Binney Street and Fulkerson Street',
                         count:        900,
                         location:     [-71.09, 42.36],
                         observed_at:  Time.now.utc,
                         source_url:   'https://example/ped',
                         **attrs
                       ))
  end

  def upsert_tree(external_id, attrs = {})
    Muni::Store.upsert(Muni::Records::Tree.new(
                         external_id:    external_id,
                         hall:           'cambridge',
                         species_common: 'Red Maple',
                         condition:      'Tree',
                         ownership:      'City',
                         location:       [-71.12, 42.37],
                         **attrs
                       ))
  end

  def park_geometry(lon = -71.10, lat = 42.36)
    {
      'type'        => 'Polygon',
      'coordinates' => [
        [
          [lon - 0.0001, lat - 0.0001],
          [lon + 0.0001, lat - 0.0001],
          [lon + 0.0001, lat + 0.0001],
          [lon - 0.0001, lat + 0.0001],
          [lon - 0.0001, lat - 0.0001]
        ]
      ]
    }
  end

  def upsert_park(external_id, attrs = {})
    Muni::Store.upsert(Muni::Records::Park.new(
                         external_id: external_id,
                         hall:        'cambridge',
                         name:        'Dana Park',
                         owner:       'City',
                         park_type:   'City park',
                         fcode:       1,
                         oscode:      1,
                         rcode:       347,
                         acres:       1.4,
                         location:    [-71.10, 42.36],
                         geometry:    park_geometry,
                         source_url:  'https://gis.cambridgema.gov/arcgis/rest/services/CDDBasemap/MapServer/348',
                         **attrs
                       ))
  end

  def upsert_food_truck(external_id, attrs = {})
    Muni::Store.upsert(Muni::Records::FoodTruck.new(
                         external_id:      external_id,
                         hall:             'cambridge',
                         status:           'Complete',
                         business_name:    'Truth Juice LLC',
                         truck_name:       'Truth Juice On The Run',
                         weekday:          'Monday',
                         hours:            '8:00am - 8:00pm',
                         open_time:        '8:00 AM',
                         close_time:       '8:00 PM',
                         address:          '1151 Massachusetts Ave, Cambridge, MA',
                         business_address: '1151 Massachusetts Ave, Cambridge, MA',
                         issued_at:        Time.now.utc,
                         location:         [-71.1135, 42.3721],
                         source_url:       'https://data.cambridgema.gov/d/qweb-m8r8',
                         **attrs
                       ))
  end

  def seed_food_truck_surface_records
    upsert_food_truck('truck/older', issued_at: Time.utc(2026, 5, 1))
    upsert_food_truck('truck/newer', issued_at: Time.utc(2026, 6, 1))
    upsert_food_truck('truck/tuesday', weekday: 'Tuesday', issued_at: Time.utc(2026, 6, 1))
    upsert_food_truck(
      'truck/event-only',
      truck_name: 'The Cookie Monstah',
      hours:      'As needed, for events',
      open_time:  '11:00 AM',
      close_time: '2:00 PM',
      address:    'Various',
      location:   [-71.1135, 42.3721]
    )
    upsert_food_truck(
      'truck/unknown-hours',
      truck_name: 'Unknown Hours Truck',
      hours:      'Unknown',
      open_time:  nil,
      close_time: nil,
      address:    '1151 Massachusetts Ave, Cambridge, MA',
      location:   [-71.1135, 42.3721]
    )
  end

  def parking_geometry(lon = -71.11, lat = 42.37)
    {
      'type'        => 'MultiPolygon',
      'coordinates' => [
        [
          [
            [lon - 0.0001, lat - 0.0001],
            [lon + 0.0001, lat - 0.0001],
            [lon + 0.0001, lat + 0.0001],
            [lon - 0.0001, lat + 0.0001],
            [lon - 0.0001, lat - 0.0001]
          ]
        ]
      ]
    }
  end

  def upsert_metered_parking_space(external_id, attrs = {})
    Muni::Store.upsert(Muni::Records::MeteredParkingSpace.new(
                         external_id:         external_id,
                         hall:                'cambridge',
                         space_id:            external_id.split('/').last,
                         pay_by_phone_zone:   '1234',
                         max_minutes:         120,
                         max_time_label:      '2 hours',
                         hourly_rate:         2.0,
                         rate_label:          '$2/hr',
                         minutes_per_payment: 7.5,
                         operation_hours:     '8:00AM-8:00PM',
                         operation_window:    '8 AM-8 PM',
                         rule_status:         'rules_known',
                         smart_meter:         'Y',
                         location:            [-71.11, 42.37],
                         geometry:            parking_geometry,
                         collected_at:        Time.utc(2026, 6, 15, 12),
                         last_seen_at:        Time.utc(2026, 6, 15, 12),
                         source_url:          'https://data.cambridgema.gov/Transportation/Metered-Parking-Spaces/kvrt-t8v3',
                         **attrs
                       ))
  end

  def seed_metered_parking_pair
    upsert_metered_parking_space('metered-parking/A001')
    upsert_metered_parking_space(
      'metered-parking/A002',
      space_id: 'A002', rule_status: 'unknown_rules', max_minutes: nil, hourly_rate: nil,
      max_time_label: 'Unknown', rate_label: 'Unknown', operation_hours: nil,
      operation_window: 'Unknown', location: [-71.111, 42.371], geometry: parking_geometry(-71.111, 42.371)
    )
  end

  def seed_dashboard_records(now)
    upsert_service_request('sr/closed', status:     'Closed',
                                        opened_at:  now - (2 * 24 * 60 * 60),
                                        updated_at: now - (24 * 60 * 60),
                                        closed_at:  now - (24 * 60 * 60))
    upsert_police_log('pd/dashboard', occurred_at: now - 3600, reported_at: now)
    upsert_crime_report('crime/dashboard', reported_at: now - 3600)
    upsert_dispatch_call('dispatch/dashboard', received_at: now - 3600)
    upsert_cpd_crash('cpd-crash/dashboard', occurred_at: now - 3600)
    upsert_traffic_volume('traffic/dashboard', observed_at: now - 3600)
    upsert_bicycle_count('bike/dashboard', observed_at: now - 1800)
    upsert_pedestrian_count('ped/dashboard', observed_at: now - 2400)
    upsert_permit('permit/dashboard', issued_at: now - 3600)
    upsert_crash('crash/dashboard', injury: true, cyclist: true, occurred_at: now - 3600)
    upsert_tree('tree/dashboard', plant_date: Time.utc(2024, 4, 1))
  end

  def seed_digest_source_item(now)
    upsert_digest_item(
      'cambridge/city_news',
      external_id:  'news/api',
      title:        'Cooling centers open today',
      source_name:  'Official City News',
      source_type:  'official_record',
      item_type:    'announcement',
      section_hint: 'today_in_cambridge',
      summary:      'The City opened cooling centers during the heat advisory.',
      category:     'services',
      url:          'https://www.cambridgema.gov/news/cooling',
      published_at: now,
      fetched_at:   now,
      tags:         ['weather'],
      confidence:   0.95,
      dedupe_key:   'cooling-centers'
    )
  end

  def upsert_digest_item(source_slug, attrs = {})
    now = attrs[:published_at] || attrs[:event_start_at] || Time.now.utc
    Muni::Store.upsert(Muni::Records::DigestItem.new(**{
      external_id:    attrs.fetch(:external_id),
      hall:           attrs.fetch(:hall, 'cambridge'),
      source_slug:    source_slug,
      source_name:    attrs.fetch(:source_name, source_slug.split('/').last.tr('_', ' ')),
      source_type:    attrs.fetch(:source_type, 'official_record'),
      item_type:      attrs.fetch(:item_type, 'announcement'),
      section_hint:   attrs[:section_hint],
      title:          attrs.fetch(:title),
      summary:        attrs[:summary],
      category:       attrs[:category],
      url:            attrs[:url],
      published_at:   attrs[:published_at],
      event_start_at: attrs[:event_start_at],
      event_end_at:   attrs[:event_end_at],
      fetched_at:     attrs.fetch(:fetched_at, now),
      tags:           attrs.fetch(:tags, []),
      confidence:     attrs[:confidence],
      dedupe_key:     attrs[:dedupe_key]
    }.compact))
  end

  def seed_shared_digest_source_scope(now)
    upsert_digest_item('cambridge/city_news',
                       external_id:  'news/source-scope',
                       title:        'Cooling centers open',
                       published_at: now)
    upsert_digest_item('cambridge/city_calendar',
                       external_id:    'calendar/source-scope',
                       title:          'Summer concert',
                       source_name:    'City Calendar',
                       source_type:    'event_listing',
                       item_type:      'event',
                       event_start_at: now + 3600)
  end

  def upsert_event(external_id, attrs = {})
    record_attrs = {
      external_id:    external_id,
      hall:           'cambridge',
      source_slug:    'cambridge/city_calendar',
      source_name:    'City Calendar',
      source_type:    'event_listing',
      item_type:      'event',
      section_hint:   'around_town',
      title:          'Official Jazz Night',
      summary:        'A city-listed outdoor jazz event.',
      category:       'music',
      url:            'https://www.cambridgema.gov/citycalendar/jazz',
      event_start_at: Time.utc(2026, 6, 18, 23),
      event_end_at:   Time.utc(2026, 6, 19, 1),
      fetched_at:     Time.utc(2026, 6, 18, 12),
      location_name:  'City Hall Lawn',
      tags:           %w[calendar music],
      dedupe_key:     external_id,
      metadata:       { 'all_day' => false }
    }.merge(attrs)
    Muni::Store.upsert(Muni::Records::DigestItem.new(**record_attrs))
  end

  def seed_delayed_crash_batch(now)
    day = 24 * 60 * 60
    upsert_crash('crash/latest-batch', crash_type: 'Batch crash', occurred_at: now - (20 * day))
    upsert_crash('crash/same-batch', crash_type: 'Batch crash', occurred_at: now - (45 * day))
    upsert_crash('crash/older-batch', occurred_at: now - (60 * day))
    upsert_crash('crash/historical', occurred_at: Time.utc(2016, 6, 30, 12, 0, 0))
  end

  def seed_sparse_permit_batch(now)
    day = 24 * 60 * 60
    upsert_permit('permit/latest-batch', issued_at: now - (10 * day))
    upsert_permit('permit/same-batch', issued_at: now - (20 * day))
    upsert_permit('permit/older-batch', issued_at: now - (45 * day))
  end

  def seed_analytics_records(now)
    day = 24 * 60 * 60
    [1, 2, 3].each do |days|
      upsert_service_request("sr/model/#{days}", status: 'Closed', opened_at: now - (days * day),
                                                 closed_at: now)
    end
    [3, 5, 7].each do |days|
      upsert_permit("permit/model/#{days}", permit_type: 'Building', property_use: 'Residential',
                                             declared_valuation: 75_000, applied_at: now - (days * day),
                                             issued_at: now)
    end
    upsert_crash('crash/model/1', injury: true, cyclist: true,
                                  location_description: 'Mass Ave at Main St',
                                  occurred_at: now - 3600)
  end

  def record_ids(path)
    get path
    JSON.parse(last_response.body).map { |r| r['external_id'] }
  end

  def expect_permit_ids(path, include_ids:, exclude_ids:)
    ids = record_ids(path)
    expect(ids).to include(*include_ids)
    expect(ids).not_to include(*exclude_ids)
  end

  def expect_record_ids(path, include_ids:, exclude_ids:)
    ids = record_ids(path)
    expect(ids).to include(*include_ids)
    expect(ids).not_to include(*exclude_ids)
  end

  def feature_ids(path)
    get path
    JSON.parse(last_response.body)['features'].map { |f| f.dig('properties', 'external_id') }
  end

  def expect_dashboard_analytics_ready
    get '/api/dashboard?hall=cambridge'
    dashboard = JSON.parse(last_response.body)
    expect(dashboard.dig('analytics', 'status')).to eq('ready')
    expect(dashboard.dig('analytics', 'service_requests', 'median_days')).to eq(2.0)
    expect(dashboard['signals'].map { |signal| signal['id'] }).to include(
      '311_volume_anomalies',
      'crash_risk_hotspots'
    )
    expect(dashboard['signals'].map { |signal| signal['id'] }).not_to include(
      'eta_model_status',
      'open_311_pressure'
    )
  end

  def expect_service_source_metadata(service_source)
    expect(service_source).to include(
      'source_mode'        => 'live',
      'completeness'       => 'citywide_operational_feed',
      'last_seen_at'       => a_string_matching(/\d{4}-\d{2}-\d{2}T/),
      'latest_opened_at'   => a_string_matching(/\d{4}-\d{2}-\d{2}T/),
      'latest_updated_at'  => a_string_matching(/\d{4}-\d{2}-\d{2}T/),
      'last_collected_at'  => anything,
      'data_lag_seconds'   => anything,
      'source_lag_seconds' => a_value >= 0
    )
  end

  def expect_prediction_endpoints_ready
    expect_service_prediction_ready
    expect_permit_prediction_ready
    get '/api/predictions/crash_risks?hall=cambridge&limit=1'
    expect(JSON.parse(last_response.body)['locations'].length).to eq(1)
    get '/api/predictions/service_request_anomalies?hall=cambridge&limit=1'
    expect(JSON.parse(last_response.body)).to include('status', 'anomalies')
  end

  def expect_service_prediction_ready
    get '/api/predictions/service_requests?hall=cambridge&case_type=Pothole&department=DPW&neighborhood=Area+4'
    service_prediction = JSON.parse(last_response.body)
    expect(service_prediction['status']).to eq('ready')
    expect(service_prediction['predicted_days']).to eq(2.0)
  end

  def expect_permit_prediction_ready
    get '/api/predictions/permits?hall=cambridge&permit_type=Building&property_use=Residential&declared_valuation=75000'
    permit_prediction = JSON.parse(last_response.body)
    expect(permit_prediction['status']).to eq('ready')
    expect(permit_prediction['predicted_days']).to eq(5.0)
  end

  before do
    Muni::Store.ensure_tables!
    Muni::Store.upsert(Muni::Records::ServiceRequest.new(
                         external_id: 'sr/1', hall: 'cambridge', case_type: 'Pothole',
                         status: 'Open', department: 'DPW', neighborhood: 'Cambridgeport',
                         description: 'big hole', location: [-71.12, 42.37],
                         opened_at: Time.now.utc, source_url: 'https://example/1'
                       ))
  end

  it 'renders the shell HTML at /' do
    get '/?hall=cambridge'
    expect(last_response).to be_ok
    expect(last_response.body).to include('Muni')
    expect(last_response.body).to include('Cambridge, MA')
  end

  it 'lists halls at /api/halls' do
    get '/api/halls'
    expect(last_response).to be_ok
    halls = JSON.parse(last_response.body)
    expect(halls.map { |h| h['slug'] }).to match_array(%w[boston cambridge])
  end

  it 'returns categories scoped to a hall' do
    get '/api/categories?hall=cambridge'
    cats = JSON.parse(last_response.body)
    slugs = cats.map { |c| c['slug'] }
    expect(slugs).to eq(%w[
                          service_requests safety police crime_reports dispatch_calls crashes
                          permits developments zoning_appeals parking environment trees parks food_trucks events
                        ])
    expect(cats.map { |c| c['section'] }).not_to include('Food & Health')
    expect(slugs).not_to include('traffic_volume', 'bicycle_counts', 'pedestrian_counts')
  end

  it 'returns category metadata scoped to a hall' do
    get '/api/categories?hall=cambridge'
    by_slug = JSON.parse(last_response.body).to_h { |c| [c['slug'], c] }
    expect(by_slug.fetch('service_requests')).to include('icon' => 'rss')
    expect(by_slug.fetch('safety')).to include('section' => 'Safety', 'icon' => 'caution')
    expect(by_slug.fetch('crime_reports')).to include('title' => 'Crime', 'icon' => 'handcuffs')
    expect(by_slug.fetch('permits')).to include('icon' => 'paper')
    expect(by_slug.fetch('developments')).to include('title' => 'Development', 'icon' => 'hammer')
    expect(by_slug.fetch('food_trucks')).to include(
      'section' => 'Food Trucks', 'icon' => 'truck', 'default_widget' => 'map'
    )
    expect(by_slug.fetch('environment')).to include(
      'section'      => 'Environment',
      'title'        => 'Environment',
      'icon'         => 'leaf',
      'source_slugs' => %w[cambridge/tree_inventory cambridge/parks]
    )
    expect(by_slug.fetch('trees')).to include('section' => 'Environment', 'title' => 'Trees', 'icon' => 'tree-pine')
    expect(by_slug.fetch('parks')).to include('section' => 'Environment', 'title' => 'Parks', 'icon' => 'map')
    expect(by_slug.fetch('police')).to include('default_widget' => 'map')
  end

  it 'returns events category metadata' do
    get '/api/categories?hall=cambridge'
    events = JSON.parse(last_response.body).find { |cat| cat['slug'] == 'events' }

    expect(events).to include(
      'section'        => 'Events',
      'icon'           => 'calendar',
      'default_widget' => 'list',
      'source_slugs'   => %w[cambridge/city_calendar cambridge/tourism_events]
    )
  end

  it 'returns parking category metadata' do
    get '/api/categories?hall=cambridge'
    parking = JSON.parse(last_response.body).find { |cat| cat['slug'] == 'parking' }

    expect(parking).to include(
      'section' => 'Parking', 'icon' => 'parking', 'default_widget' => 'map',
      'source_slugs' => ['cambridge/metered_parking_spaces']
    )
  end

  it 'combines recent and historical crash feeds into Collisions' do
    get '/api/categories?hall=cambridge'
    collisions = JSON.parse(last_response.body).find { |cat| cat['slug'] == 'crashes' }

    expect(collisions).to include(
      'title'        => 'Collisions',
      'icon'         => 'car-burst',
      'source_slugs' => %w[cambridge/vision_zero_crashes cambridge/cpd_crash_log]
    )
  end

  it 'merges construction and major development records into the Development category' do
    upsert_new_construction('new-construction/1')
    upsert_development_project('development/1')

    get '/api/category/developments/records?hall=cambridge&limit=10'
    expect(last_response).to be_ok
    rows = JSON.parse(last_response.body)
    expect(rows.map { |row| row['_source_slug'] }).to include(
      'cambridge/new_construction_permits',
      'cambridge/development_log'
    )
  end

  it 'keeps mobility count feeds out of map categories but available as sources' do
    upsert_traffic_volume('traffic/source')
    upsert_bicycle_count('bike/source')
    upsert_pedestrian_count('ped/source')

    get '/api/category/traffic_volume/records?hall=cambridge&limit=10'
    expect(last_response.status).to eq(404)

    get '/api/category/bicycle_counts/geo?hall=cambridge&limit=10'
    expect(last_response.status).to eq(404)

    get '/api/records/cambridge/traffic_volume_daily?hall=cambridge&limit=10'
    expect(last_response).to be_ok
    expect(JSON.parse(last_response.body).first['intersection']).to eq('Mass Ave and Main St')

    get '/api/records/cambridge/bicycle_counts?hall=cambridge&limit=10'
    expect(last_response).to be_ok
    expect(JSON.parse(last_response.body).first['count_location']).to eq('Concord Ave and Garden St')

    get '/api/records/cambridge/pedestrian_counts?hall=cambridge&limit=10'
    expect(last_response).to be_ok
    expect(JSON.parse(last_response.body).first['intersection']).to eq('Binney Street and Fulkerson Street')
  end

  it 'returns records for a given source' do
    get '/api/records/cambridge/service_requests?hall=cambridge'
    expect(last_response).to be_ok
    rows = JSON.parse(last_response.body)
    expect(rows.size).to eq(1)
    expect(rows.first['case_type']).to eq('Pothole')
  end

  it 'scopes shared digest records to the requested source' do
    now = Time.utc(2026, 6, 18, 12)
    seed_shared_digest_source_scope(now)

    expect_record_ids('/api/records/cambridge/city_news?hall=cambridge&limit=10',
                      include_ids: ['news/source-scope'], exclude_ids: ['calendar/source-scope'])
    expect_record_ids('/api/records/cambridge/city_calendar?hall=cambridge&limit=10',
                      include_ids: ['calendar/source-scope'], exclude_ids: ['news/source-scope'])

    get '/api/records/cambridge/city_news/calendar%2Fsource-scope?hall=cambridge'
    expect(last_response.status).to eq(404)
  end

  it 'returns GeoJSON for a given source' do
    get '/api/geo/cambridge/service_requests?hall=cambridge'
    expect(last_response).to be_ok
    payload = JSON.parse(last_response.body)
    expect(payload['type']).to eq('FeatureCollection')
    expect(payload['features'].size).to eq(1)
    expect(payload['features'].first['geometry']['coordinates']).to eq([-71.12, 42.37])
  end

  it 'clips source GeoJSON to the hall boundary' do
    upsert_service_request('sr/somerville', location: [-71.10, 42.39])

    get '/api/geo/cambridge/service_requests?hall=cambridge'

    payload = JSON.parse(last_response.body)
    ids = payload['features'].map { |feature| feature.dig('properties', 'external_id') }
    expect(ids).to include('sr/1')
    expect(ids).not_to include('sr/somerville')
  end

  it 'clips category GeoJSON to the hall boundary' do
    upsert_service_request('sr/somerville', location: [-71.10, 42.39])

    get '/api/category/service_requests/geo?hall=cambridge'

    payload = JSON.parse(last_response.body)
    ids = payload['features'].map { |feature| feature.dig('properties', 'external_id') }
    expect(ids).to include('sr/1')
    expect(ids).not_to include('sr/somerville')
  end

  it 'reports healthy at /healthz' do
    get '/healthz'
    expect(last_response).to be_ok
    expect(JSON.parse(last_response.body)['ok']).to be(true)
  end

  it 'returns the public Muni status contract as JSON' do
    get '/status.json'

    expect(last_response).to be_ok
    payload = JSON.parse(last_response.body)
    expect(payload).to include(
      'schema_version' => 1,
      'hall'           => 'cambridge',
      'overall_status' => a_string_matching(/\A(operational|degraded|outage)\z/)
    )
    expect(payload).to include('summary', 'checks', 'sources', 'metrics')
    expect(payload['backup']).to include('status', 'last_success_at', 'age_seconds', 'retention', 'failure_state')
    service_source = payload['sources'].find { |source| source['source'] == 'cambridge/service_requests' }
    expect(service_source).to include(
      'label'        => '311 service requests',
      'source_mode'  => 'live',
      'row_count'    => a_value >= 1,
      'completeness' => 'citywide_operational_feed'
    )
  end

  it 'aliases /api/status to the same public-safe status schema' do
    get '/api/status?hall=cambridge'

    expect(last_response).to be_ok
    payload = JSON.parse(last_response.body)
    expect(payload.keys).to include('schema_version', 'overall_status', 'summary', 'checks', 'sources', 'metrics')
    expect(last_response.body).not_to include('big hole', 'private_token', 'description')
  end

  it 'returns facets for a source with distinct values from the store' do
    get '/api/facets/cambridge/service_requests?hall=cambridge'
    expect(last_response).to be_ok
    facets = JSON.parse(last_response.body)
    time_facet = facets.find { |f| f['name'] == 'time_range' }
    status_facet = facets.find { |f| f['name'] == 'status' }
    case_type_facet = facets.find { |f| f['name'] == 'case_type' }
    expect(time_facet['label']).to eq('Time')
    expect(time_facet['default']).to eq('active')
    expect(time_facet['values']).to eq(%w[active latest 1d 2d 7d 14d 30d 90d])
    expect(time_facet['source_anchored']).to be(true)
    expect(status_facet['label']).to eq('Status')
    expect(status_facet['values']).to include('Open')
    expect(case_type_facet['label']).to eq('Case type')
    expect(case_type_facet['values']).to include('Pothole')
  end

  it 'returns category-level facets for the safety overview' do
    upsert_crime_report('crime/facet')
    upsert_dispatch_call('dispatch/facet')

    get '/api/category/safety/facets?hall=cambridge'

    expect(last_response).to be_ok
    facets = JSON.parse(last_response.body)
    expect(facets.find { |f| f['name'] == 'time_range' }['default']).to eq('latest')
    expect(facets.find { |f| f['name'] == 'incident_kind' }['values']).to include('Crime', 'Fire dispatch')
    expect(facets.find { |f| f['name'] == 'neighborhood' }['values']).to include('Area 4')
  end

  it 'returns official events records for the default today-forward window' do
    allow(Time).to receive(:now).and_return(Time.utc(2026, 6, 18, 22))
    upsert_event('event-api')
    upsert_event(
      'event-api-tomorrow',
      title:          'Official Art Walk',
      event_start_at: Time.utc(2026, 6, 19, 22),
      event_end_at:   Time.utc(2026, 6, 20, 0),
      dedupe_key:     'event-api-tomorrow'
    )

    get '/api/category/events/records?hall=cambridge&limit=10'
    rows = JSON.parse(last_response.body)
    expect(rows.map { |row| row['external_id'] }).to eq(%w[event-api event-api-tomorrow])
    expect(rows.first).to include(
      'item_type'     => 'event',
      'source_type'   => 'event_listing',
      'location_name' => 'City Hall Lawn'
    )
  end

  it 'returns official events facets' do
    allow(Time).to receive(:now).and_return(Time.utc(2026, 6, 18, 22))
    upsert_event('event-api')

    get '/api/category/events/facets?hall=cambridge'
    facets = JSON.parse(last_response.body)
    time = facets.find { |facet| facet['name'] == 'time_range' }
    expect(time).to include('default' => 'upcoming', 'future' => true)
    expect(time['values']).to eq(%w[upcoming today tonight tomorrow 7d 30d])
    expect(facets.find { |facet| facet['name'] == 'source_name' }['values']).to include('City Calendar')
  end

  it 'returns official event detail payloads' do
    upsert_event('event-api')

    get '/api/records/cambridge/city_calendar/event-api?hall=cambridge'
    detail = JSON.parse(last_response.body)
    expect(detail['external_id']).to eq('event-api')
    expect(detail['event_start_at']).to eq('2026-06-18T23:00:00Z')
    expect(detail['url']).to eq('https://www.cambridgema.gov/citycalendar/jazz')
  end

  it 'returns and filters multi-source safety overview records and map points' do
    upsert_crime_report('crime/safety', reported_at: Time.now.utc - 60)
    upsert_dispatch_call('dispatch/safety', agency: 'Fire', received_at: Time.now.utc)
    upsert_cpd_crash('cpd/safety', occurred_at: Time.now.utc - 120)

    get '/api/category/safety/records?hall=cambridge&time_range=30d&incident_kind=Fire+dispatch&limit=10'
    rows = JSON.parse(last_response.body)
    expect(rows.map { |row| row['external_id'] }).to eq(['dispatch/safety'])
    expect(rows.first['_incident_kind']).to eq('dispatch_fire')
    expect(rows.first['received_at']).to match(/\A\d{4}-\d{2}-\d{2}T.*Z\z/)

    get '/api/category/safety/geo?hall=cambridge&time_range=30d&limit=10'
    features = JSON.parse(last_response.body)['features']
    expect(features.map { |feature| feature.dig('properties', '_source_slug') }).to include(
      'cambridge/crime_reports',
      'cambridge/dispatch_calls',
      'cambridge/cpd_crash_log'
    )
  end

  it 'exposes active as the default 311 time facet' do
    get '/api/category/service_requests/facets?hall=cambridge'

    time = JSON.parse(last_response.body).find { |facet| facet['name'] == 'time_range' }
    expect(time).to include('default' => 'active', 'values' => %w[active latest 1d 2d 7d 14d 30d 90d all])
  end

  it 'defaults 311 category records and map points to active lifecycle visibility' do
    Muni::Store.db[:service_requests].delete
    now = Time.now.utc
    seed_lifecycle_service_requests(now: now, location: [-71.11, 42.37])
    upsert_service_request('sr/open-recent', status: 'Open', location: [-71.11, 42.37],
                                             opened_at: now - 60, updated_at: now - 60,
                                             collected_at: now)

    get '/api/category/service_requests/records?hall=cambridge&limit=20'
    rows = JSON.parse(last_response.body)
    default_ids = rows.map { |row| row['external_id'] }
    expect(default_ids).to include('sr/open-old', 'sr/closed-recent', 'sr/stale', 'sr/open-recent')
    expect(default_ids).not_to include('sr/closed-old')
    expect_stale_lifecycle_payload(rows, now: now)

    default_map_ids = feature_ids('/api/category/service_requests/geo?hall=cambridge&time_range=active&limit=20')
    expect(default_map_ids).to include('sr/stale', 'sr/open-recent')
    expect(default_map_ids).not_to include('sr/open-old', 'sr/closed-recent', 'sr/closed-old')

    latest_ids = feature_ids('/api/category/service_requests/geo?hall=cambridge&time_range=latest&limit=20')
    expect(latest_ids).to include('sr/open-recent', 'sr/stale')
    expect(latest_ids).not_to include('sr/open-old', 'sr/closed-recent', 'sr/closed-old')

    thirty_day_ids = record_ids('/api/category/service_requests/records?hall=cambridge&time_range=30d&limit=10')
    expect(thirty_day_ids).to include('sr/open-old', 'sr/closed-recent', 'sr/stale')
  end

  it 'scopes the 311 list to the map while keeping older and closed reports in history' do
    Muni::Store.db[:service_requests].delete
    now = Time.now.utc
    seed_lifecycle_service_requests(now: now, location: [-71.11, 42.37])
    upsert_service_request('sr/open-recent', opened_at: now - 60, location: [-71.11, 42.37])

    get '/api/category/service_requests/records?hall=cambridge&map_view=1&bbox=-71.2,42.3,-71.0,42.5'
    ids = JSON.parse(last_response.body).map { |row| row['external_id'] }
    expect(ids).to contain_exactly('sr/stale', 'sr/open-recent')

    get '/api/category/service_requests/records?hall=cambridge&history_view=1&limit=20'
    expect(JSON.parse(last_response.body).map { |row| row['external_id'] }).to include('sr/closed-old', 'sr/open-old')

    first = record_ids('/api/category/service_requests/records?hall=cambridge&history_view=1&time_range=all&limit=2')
    second_url = '/api/category/service_requests/records?hall=cambridge&history_view=1&time_range=all&limit=2&offset=2'
    second = record_ids(second_url)
    expect(first.length).to eq(2)
    expect(second.length).to eq(2)
    expect(first & second).to be_empty
  end

  it 'does not let newer closed rows hide eligible map points' do
    Muni::Store.db[:service_requests].delete
    now = Time.now.utc
    location = [-71.11, 42.37]
    upsert_service_request('sr/recent-open', status: 'Open', location: location,
                                               opened_at: now - (24 * 60 * 60),
                                               updated_at: now - (24 * 60 * 60),
                                               collected_at: now)
    seed_newer_closed_service_requests(count: 5_001, now: now, location: location)

    ids = feature_ids('/api/category/service_requests/geo?hall=cambridge&time_range=active')
    expect(ids).to eq(['sr/recent-open'])
  end

  it 'filters 311 category records and map points by requested source timestamp field' do
    Muni::Store.db[:service_requests].delete
    now = Time.utc(2026, 6, 18, 12, 0, 0)
    day = 24 * 60 * 60
    location = [-71.11, 42.37]

    upsert_service_request('sr/closed-recent', status: 'Closed', location: location,
                                               opened_at: now - (20 * day), closed_at: now,
                                               updated_at: now)
    upsert_service_request('sr/opened-recent', status: 'Open', location: location,
                                               opened_at: now - day, updated_at: now - day)
    upsert_service_request('sr/closed-old', status: 'Closed', location: location,
                                            opened_at: now - (20 * day), closed_at: now - (5 * day),
                                            updated_at: now - (5 * day))

    records_path = '/api/category/service_requests/records?hall=cambridge&time_range=2d&time_field=closed_at&limit=10'
    ids = record_ids(records_path)
    expect(ids).to eq(['sr/closed-recent'])

    geo_path = '/api/category/service_requests/geo?hall=cambridge&time_range=2d&time_field=closed_at&limit=10'
    expect(feature_ids(geo_path)).to be_empty
  end

  it 'exposes source-anchored sparse permit time facets' do
    seed_sparse_permit_batch(Time.now.utc)

    get '/api/facets/cambridge/building_permits?hall=cambridge'
    facets = JSON.parse(last_response.body)
    time_facet = facets.find { |f| f['name'] == 'time_range' }

    expect(time_facet).to include(
      'default'         => 'latest',
      'values'          => %w[latest 1d 2d 7d 14d 30d 90d],
      'source_anchored' => true
    )
  end

  it 'filters sparse permit records from the latest official report date' do
    seed_sparse_permit_batch(Time.now.utc)

    expect_permit_ids('/api/category/permits/records?hall=cambridge&limit=10',
                      include_ids: %w[permit/latest-batch permit/same-batch],
                      exclude_ids: %w[permit/older-batch])

    map_ids = feature_ids('/api/category/permits/geo?hall=cambridge&limit=10')
    expect(map_ids).to include('permit/latest-batch', 'permit/same-batch')
    expect(map_ids).not_to include('permit/older-batch')

    expect_permit_ids('/api/category/permits/records?hall=cambridge&time_range=30d&limit=10',
                      include_ids: %w[permit/latest-batch permit/same-batch],
                      exclude_ids: %w[permit/older-batch])

    %w[1d 2d 7d].each do |range|
      expect_permit_ids("/api/category/permits/records?hall=cambridge&time_range=#{range}&limit=10",
                        include_ids: %w[permit/latest-batch],
                        exclude_ids: %w[permit/same-batch permit/older-batch])
    end
  end

  it 'defaults sparse zoning appeals to the latest official batch window' do
    upsert_zoning_appeal('zoning/latest-batch', applied_at: Time.now.utc - (45 * 24 * 60 * 60))
    upsert_zoning_appeal('zoning/older-batch', applied_at: Time.now.utc - (90 * 24 * 60 * 60))

    get '/api/facets/cambridge/zoning_appeals?hall=cambridge'
    facets = JSON.parse(last_response.body)
    time_facet = facets.find { |f| f['name'] == 'time_range' }
    expect(time_facet['default']).to eq('latest')

    get '/api/category/zoning_appeals/records?hall=cambridge&limit=10'
    default_ids = JSON.parse(last_response.body).map { |r| r['external_id'] }
    expect(default_ids).to include('zoning/latest-batch')
    expect(default_ids).not_to include('zoning/older-batch')

    get '/api/category/zoning_appeals/records?hall=cambridge&time_range=7d&limit=10'
    seven_day_ids = JSON.parse(last_response.body).map { |r| r['external_id'] }
    expect(seven_day_ids).not_to include('zoning/latest-batch')
  end

  it 'defaults crash records to the latest official batch window' do
    seed_delayed_crash_batch(Time.now.utc)
    upsert_cpd_crash('cpd-crash/latest', occurred_at: Time.now.utc - 30)

    get '/api/facets/cambridge/vision_zero_crashes?hall=cambridge'
    facets = JSON.parse(last_response.body)
    time_facet = facets.find { |f| f['name'] == 'time_range' }
    expect(time_facet['default']).to eq('latest')
    expect(time_facet['values']).to eq(%w[latest 1d 2d 7d 14d 30d 90d])
    expect(facets.find { |f| f['name'] == 'crash_type' }['values']).to include('Batch crash')
    expect(facets.find { |f| f['name'] == 'crash_type' }['values']).not_to include('')

    ids = record_ids('/api/category/crashes/records?hall=cambridge&limit=10')
    expect(ids).to include('cpd-crash/latest', 'crash/latest-batch', 'crash/same-batch')
    expect(ids).not_to include('crash/older-batch')
    expect(ids).not_to include('crash/historical')

    map_ids = feature_ids('/api/category/crashes/geo?hall=cambridge&limit=10')
    expect(map_ids).to include('cpd-crash/latest', 'crash/latest-batch', 'crash/same-batch')
    expect(map_ids).not_to include('crash/older-batch')
  end

  it 'keeps old recent crash category links pointed at the combined Collisions list' do
    upsert_cpd_crash('cpd-crash/alias', occurred_at: Time.now.utc - 30)
    upsert_crash('crash/alias', occurred_at: Time.now.utc - 60)

    ids = record_ids('/api/category/recent_crashes/records?hall=cambridge&limit=10')

    expect(ids).to include('cpd-crash/alias', 'crash/alias')
  end

  it 'does not add a time filter to tree inventory facets' do
    Muni::Store.upsert(Muni::Records::Tree.new(
                         external_id: 'tree/1', hall: 'cambridge', species_common: 'Red Maple',
                         species_scientific: 'Acer rubrum', diameter_in: 12.5,
                         condition: 'City', location: [-71.12, 42.37]
                       ))

    get '/api/facets/cambridge/tree_inventory?hall=cambridge'
    expect(last_response).to be_ok
    facets = JSON.parse(last_response.body)
    expect(facets.map { |f| f['name'] }).not_to include('time_range')
    condition_facet = facets.find { |f| f['name'] == 'condition' }
    expect(condition_facet['label']).to eq('Condition')
    expect(condition_facet['values']).to include('City')
    expect(facets.find { |f| f['name'] == 'species_common' }['label']).to eq('Species/site')
  end

  it 'returns only surfaceable food trucks on the public category records surface' do
    seed_food_truck_surface_records

    get '/api/category/food_trucks/records?hall=cambridge&limit=10'

    expect(last_response).to be_ok
    rows = JSON.parse(last_response.body)
    truth_juice = rows.find { |row| row['truck_name'] == 'Truth Juice On The Run' }
    expect(truth_juice).to include(
      'grouped_record' => true,
      'weekday'        => 'Mon-Tue',
      'service_days'   => %w[Monday Tuesday]
    )
    expect(truth_juice['external_id']).to start_with('food-truck-business/')
    expect(truth_juice['business_id']).to eq(truth_juice['external_id'])
    expect(truth_juice['source_external_ids']).to include('truck/newer', 'truck/tuesday')
    expect(truth_juice['source_external_ids']).not_to include('truck/older')
    expect(rows.map { |row| row['truck_name'] }).not_to include('The Cookie Monstah', 'Unknown Hours Truck')
  end

  it 'filters food truck geojson and facets to public surfaceable stops' do
    seed_food_truck_surface_records

    get '/api/category/food_trucks/geo?hall=cambridge&limit=10'

    expect(last_response).to be_ok
    geo = JSON.parse(last_response.body)
    expect(geo['features'].map { |feature| feature.dig('properties', 'external_id') }).to include('truck/newer')
    expect(geo['features'].map { |feature| feature.dig('properties', 'external_id') })
      .not_to include('truck/older', 'truck/event-only', 'truck/unknown-hours')

    get '/api/category/food_trucks/facets?hall=cambridge'
    expect(last_response).to be_ok
    truck_facet = JSON.parse(last_response.body).find { |facet| facet['name'] == 'truck_name' }
    expect(truck_facet['values']).to include('Truth Juice On The Run')
    expect(truck_facet['values']).not_to include('The Cookie Monstah', 'Unknown Hours Truck')
  end

  it 'keeps non-surfaceable food truck permits in the source inventory API' do
    seed_food_truck_surface_records

    get '/api/records/cambridge/food_trucks?hall=cambridge&limit=10'

    expect(last_response).to be_ok
    source_rows = JSON.parse(last_response.body)
    expect(source_rows.map { |row| row['truck_name'] }).to include('Truth Juice On The Run')
    expect(source_rows.map { |row| row['truck_name'] }).to include('The Cookie Monstah', 'Unknown Hours Truck')
  end

  it 'returns and filters metered parking records on the public category surface' do
    seed_metered_parking_pair

    get '/api/category/parking/records?hall=cambridge&meter_status=Unknown+rules&limit=10'
    expect(last_response).to be_ok
    rows = JSON.parse(last_response.body)
    expect(rows.map { |row| row['space_id'] }).to eq(['A002'])
    expect(rows.first).to include('meter_status' => 'Unknown rules')
  end

  it 'returns metered parking facets on the public category surface' do
    seed_metered_parking_pair

    get '/api/category/parking/facets?hall=cambridge'
    expect(last_response).to be_ok
    facets = JSON.parse(last_response.body)
    expect(facets.find { |f| f['name'] == 'meter_status' }['values']).to include('Paid now', 'Unknown rules')
    expect(facets.find { |f| f['name'] == 'rate' }['values']).to include('$2/hr', 'Unknown')
    expect(facets.find { |f| f['name'] == 'max_time' }['values']).to include('2 hours', 'Unknown')
    expect(facets.find { |f| f['name'] == 'operation_window' }['values']).to include('8 AM-8 PM', 'Unknown')
  end

  it 'returns metered parking polygon GeoJSON on the public category surface' do
    seed_metered_parking_pair

    get '/api/category/parking/geo?hall=cambridge&limit=5000'
    expect(last_response).to be_ok
    geo = JSON.parse(last_response.body)
    feature = geo['features'].find { |candidate| candidate.dig('properties', 'external_id') == 'metered-parking/A001' }
    expect(feature.dig('geometry', 'type')).to eq('MultiPolygon')
    expect(feature.dig('properties', 'location')).to eq([-71.11, 42.37])
    expect(feature.dig('properties', 'geometry')).to be_nil
  end

  it 'returns park polygon GeoJSON on the public category surface' do
    upsert_park('parks/1')

    get '/api/category/parks/geo?hall=cambridge&limit=2000'
    expect(last_response).to be_ok
    geo = JSON.parse(last_response.body)
    feature = geo['features'].find { |candidate| candidate.dig('properties', 'external_id') == 'parks/1' }
    expect(feature.dig('geometry', 'type')).to eq('Polygon')
    expect(feature.dig('properties', 'name')).to eq('Dana Park')
    expect(feature.dig('properties', 'geometry')).to be_nil
  end

  it 'returns mixed Environment GeoJSON for tree points and park polygons' do
    upsert_tree('tree/1')
    upsert_park('parks/1')

    get '/api/category/environment/geo?hall=cambridge&limit=10'
    expect(last_response).to be_ok
    geo = JSON.parse(last_response.body)
    by_id = geo['features'].to_h { |feature| [feature.dig('properties', 'external_id'), feature] }
    expect(by_id.dig('tree/1', 'geometry', 'type')).to eq('Point')
    expect(by_id.dig('parks/1', 'geometry', 'type')).to eq('Polygon')
  end

  it 'interleaves Environment records from trees and parks' do
    upsert_tree('tree/1')
    upsert_tree('tree/2')
    upsert_park('parks/1')
    upsert_park('parks/2')

    get '/api/category/environment/records?hall=cambridge&limit=4'
    expect(last_response).to be_ok
    records = JSON.parse(last_response.body)
    expect(records.map { |row| row['_source_slug'] }).to eq(
      %w[cambridge/tree_inventory cambridge/parks cambridge/tree_inventory cambridge/parks]
    )
  end

  it 'returns Environment and Parks facets on the public category surface' do
    upsert_tree('tree/1')
    upsert_park('parks/1')

    get '/api/category/environment/facets?hall=cambridge'
    expect(last_response).to be_ok
    environment_facets = JSON.parse(last_response.body)
    expect(environment_facets.find { |f| f['name'] == 'kind' }['values']).to eq(%w[Trees Parks])

    get '/api/category/parks/facets?hall=cambridge'
    expect(last_response).to be_ok
    park_facets = JSON.parse(last_response.body)
    expect(park_facets.find { |f| f['name'] == 'park_type' }['values']).to include('City park')
    expect(park_facets.find { |f| f['name'] == 'owner' }['values']).to include('City')
  end

  it 'returns a metered parking detail record when the external id contains a slash' do
    upsert_metered_parking_space('metered-parking/A001')

    get '/api/records/cambridge/metered_parking_spaces/metered-parking%2FA001?hall=cambridge'

    expect(last_response).to be_ok
    row = JSON.parse(last_response.body)
    expect(row).to include('external_id' => 'metered-parking/A001', 'space_id' => 'A001')
  end

  it 'checks nearby parking guidance for a requested location and duration' do
    upsert_metered_parking_space('metered-parking/A001')

    get '/api/parking/check?hall=cambridge&lat=42.37&lon=-71.11&arrive_at=2026-06-15T16:00:00Z&duration_minutes=90'

    expect(last_response).to be_ok
    payload = JSON.parse(last_response.body)
    expect(payload).to include(
      'confidence'   => 'inside_space',
      'meter_active' => true,
      'meter_status' => 'Paid now'
    )
    expect(payload.dig('space', 'space_id')).to eq('A001')
    expect(payload.dig('space', 'pay_by_phone_zone')).to eq('1234')
    expect(payload.dig('estimate', 'requested_minutes')).to eq(90)
    expect(payload.dig('estimate', 'billable_minutes')).to eq(90)
    expect(payload.dig('estimate', 'estimated_cost')).to eq(3.0)
    expect(payload['warnings'].join(' ')).to include('advisory')
  end

  it 'filters food truck category records and geojson by open-now schedule' do
    today = Muni::View.cambridge_local_time(Time.now.utc).strftime('%A')
    yesterday = Muni::View.cambridge_local_time(Time.now.utc - (24 * 60 * 60)).strftime('%A')
    upsert_food_truck('truck/open', weekday: today, open_time: '12:00 AM', close_time: '12:00 AM')
    upsert_food_truck('truck/closed', weekday: yesterday, open_time: '12:00 AM', close_time: '12:00 AM')

    get '/api/category/food_trucks/records?hall=cambridge&open_now=1&limit=10'
    expect(last_response).to be_ok
    rows = JSON.parse(last_response.body)
    open_business = rows.find { |row| row['source_external_ids']&.include?('truck/open') }
    expect(open_business).to include('grouped_record' => true)
    expect(open_business['external_id']).to start_with('food-truck-business/')
    expect(rows).not_to include(a_hash_including('source_external_ids' => include('truck/closed')))

    get '/api/category/food_trucks/geo?hall=cambridge&open_now=1&limit=10'
    expect(last_response).to be_ok
    geo = JSON.parse(last_response.body)
    geo_ids = geo['features'].map { |feature| feature.dig('properties', 'external_id') }
    expect(geo_ids).to include('truck/open')
    expect(geo_ids).not_to include('truck/closed')
  end

  it 'filters crash records and geojson by synthetic crash status' do
    now = Time.now.utc
    upsert_crash('crash/fatal', crash_type: 'Fatal crash',
                                injury: true, fatal: true, occurred_at: now)
    upsert_crash('crash/injury', crash_type: 'Injury crash',
                                 injury: true, occurred_at: now - 60)
    upsert_crash('crash/no-injury', crash_type:  'Property damage',
                                    occurred_at: now - 120)

    get '/api/category/crashes/records?hall=cambridge&time_range=30d&crash_status=Injury'
    rows = JSON.parse(last_response.body)
    expect(rows.map { |r| r['external_id'] }).to eq(['crash/injury'])

    get '/api/category/crashes/geo?hall=cambridge&time_range=30d&crash_status=No+injury'
    features = JSON.parse(last_response.body)['features']
    expect(features.map { |f| f.dig('properties', 'external_id') }).to eq(['crash/no-injury'])
  end

  it 'returns police facets from crime fields' do
    Muni::Store.upsert(Muni::Records::PoliceLogEntry.new(
                         external_id:       'pd/1',
                         hall:              'cambridge',
                         crime_category:    'INCIDENT',
                         crime_subcategory: 'TRAFFIC INVESTIGATIONS',
                         description:       'Police took a report.',
                         neighborhood:      'CAMBRIDGE ST',
                         occurred_at:       Time.now.utc,
                         reported_at:       Time.now.utc,
                         source_url:        'https://example/police'
                       ))

    get '/api/facets/cambridge/police_log?hall=cambridge'
    expect(last_response).to be_ok
    facets = JSON.parse(last_response.body)
    category_facet = facets.find { |f| f['name'] == 'crime_category' }
    expect(category_facet['label']).to eq('Category')
    expect(category_facet['values']).to include('INCIDENT')
    expect(facets.find { |f| f['name'] == 'crime_subcategory' }['values']).to include('TRAFFIC INVESTIGATIONS')
  end

  it 'filters records by a facet value' do
    Muni::Store.upsert(Muni::Records::ServiceRequest.new(
                         external_id: 'sr/2', hall: 'cambridge', case_type: 'Trash',
                         status: 'Closed', department: 'DPW', neighborhood: 'Area 4',
                         description: 'done', location: [-71.10, 42.31],
                         opened_at: Time.now.utc, updated_at: Time.now.utc,
                         source_url: 'https://example/2'
                       ))

    get '/api/records/cambridge/service_requests?hall=cambridge&status=Closed'
    expect(last_response).to be_ok
    rows = JSON.parse(last_response.body)
    expect(rows.size).to eq(1)
    expect(rows.first['case_type']).to eq('Trash')
  end

  it 'returns category metadata with row counts' do
    get '/api/categories?hall=cambridge'
    cats = JSON.parse(last_response.body)
    sr = cats.find { |c| c['slug'] == 'service_requests' }
    expect(sr['primary_source']).to eq('cambridge/service_requests')
    expect(sr).to have_key('row_count')
    expect(sr).to have_key('empty_message')
    expect(sr).to have_key('collecting')
  end

  it 'returns city dashboard metrics from stored normalized records' do
    seed_dashboard_records(Time.now.utc)
    upsert_service_request('sr/stale-pressure', opened_at: Time.now.utc - (31 * 24 * 60 * 60))

    get '/api/dashboard?hall=cambridge'

    expect(last_response).to be_ok
    payload = JSON.parse(last_response.body)
    widgets = payload['widgets']
    expect(payload.dig('analytics', 'status')).to eq('warming')
    expect(widgets.dig('service_requests', 'opened_last_7d')).to be >= 1
    expect(widgets.dig('service_requests', 'closed_last_7d')).to eq(1)
    expect(widgets.dig('police', 'reports_last_7d')).to eq(1)
    expect(widgets.dig('permits', 'permits_last_30d')).to eq(1)
    expect(widgets.dig('crashes', 'crashes_latest_window')).to eq(1)
    expect(widgets['trees']).to include(
      'current_tree_records'    => 1,
      'total_inventory_records' => 1,
      'total_trees'             => 1
    )
    expect(widgets).not_to have_key('freshness')
    expect(payload['signals'].map { |signal| signal['id'] }).not_to include('open_311_pressure')
  end

  it 'returns tree planting and species metrics for the inventory dashboard' do
    upsert_tree('tree/red-2024', plant_date: Time.utc(2024, 4, 1), species_common: 'Red Maple')
    upsert_tree('tree/red-2025', plant_date: Time.utc(2025, 4, 1), species_common: 'Red Maple')
    upsert_tree('tree/oak-retired',
                condition:      'Retired',
                plant_date:     Time.utc(2025, 5, 1),
                removal_date:   Time.utc(2026, 1, 1),
                species_common: 'Pin Oak')

    get '/api/dashboard?hall=cambridge'

    trees = JSON.parse(last_response.body).dig('widgets', 'trees')
    expect(trees).to include(
      'current_tree_records'    => 2,
      'total_inventory_records' => 3,
      'planting_record_count'   => 3,
      'species_count'           => 1
    )
    expect(trees['planting_trend'].last).to include('label' => '2025', 'value' => 2)
    expect(trees['by_species']).to eq([{ 'name' => 'Red Maple', 'count' => 2 }])
    expect(trees['by_condition']).to include({ 'name' => 'Retired', 'count' => 1 })
  end

  it 'returns representative mobility signal widgets for the metrics dashboard' do
    seed_dashboard_records(Time.now.utc)

    get '/api/dashboard?hall=cambridge'

    widgets = JSON.parse(last_response.body)['widgets']
    expect(widgets.dig('traffic_volume', 'total_30d')).to eq(1200)
    expect(widgets.dig('traffic_volume', 'by_class').first).to include('name' => 'Car', 'count' => 1200)
    expect(widgets.dig('bicycle_counts', 'total_30d')).to eq(42)
    expect(widgets.dig('bicycle_counts', 'hour_heat').sum { |point| point['count'] }).to eq(42)
    expect(widgets.dig('pedestrian_counts', 'total_30d')).to eq(900)
    expect(widgets.dig('pedestrian_counts', 'weekday_heat').sum { |point| point['count'] }).to eq(900)
  end

  it 'returns cached analytics on dashboard and prediction endpoints' do
    now = Time.utc(2026, 6, 16, 12, 0, 0)
    seed_analytics_records(now)
    Muni::Analytics.compute!(hall: 'cambridge', now: now)

    expect_dashboard_analytics_ready
    expect_prediction_endpoints_ready
  end

  it 'returns cached structured city digest cards' do
    now = Time.utc(2026, 6, 16, 12, 0, 0)
    seed_dashboard_records(now)
    seed_digest_source_item(now)
    Muni::Analytics.compute!(hall: 'cambridge', now: now)
    Muni::Analytics.compute_digest!(hall: 'cambridge', now: now)

    get '/api/digest?hall=cambridge'

    expect(last_response).to be_ok
    payload = JSON.parse(last_response.body)
    expect(payload).to include('schema_version' => 2, 'status' => 'ready', 'title' => 'Digest')
    expect(payload).to include('source_freshness', 'sections')
    expect(payload['cards'].first).to include('id', 'title', 'summary', 'metric', 'visual', 'href',
                                              'source_type', 'sources')
    expect(payload['cards'].first).not_to have_key('body')
  end

  it 'does not serve legacy cached metric payloads as the Digest' do
    now = Time.utc(2026, 6, 16, 12, 0, 0)
    Muni::Store.upsert_analytics_result(
      hall:             'cambridge',
      kind:             Muni::Analytics::CIVIC_DIGEST,
      key:              Muni::Analytics::DEFAULT_KEY,
      payload:          { 'title' => 'City Digest', 'body' => '# old', 'cards' => [{ 'id' => 'legacy' }] },
      generated_at:     now,
      source_row_count: 1,
      source_max_at:    now
    )

    get '/api/digest?hall=cambridge'

    payload = JSON.parse(last_response.body)
    expect(payload).to include('schema_version' => 2, 'status' => 'warming', 'title' => 'Digest')
    expect(payload['cards']).to eq([])
    expect(payload).not_to have_key('body')
  end

  it 'rejects digest requests for unknown halls' do
    get '/api/digest?hall=unknown'

    expect(last_response.status).to eq(404)
  end

  it 'returns city dashboard trend series for visual widgets' do
    seed_dashboard_records(Time.now.utc)

    get '/api/dashboard?hall=cambridge'

    widgets = JSON.parse(last_response.body)['widgets']
    opened_trend = widgets.dig('service_requests', 'opened_trend')
    expect(opened_trend.length).to be_between(1, 14).inclusive
    expect(opened_trend.last).to include('date', 'label', 'value')
    expect(opened_trend.sum { |point| point['value'] }).to be >= 1
    expect(widgets.dig('service_requests', 'closed_trend').sum { |point| point['value'] }).to be >= 1
    expect(widgets.dig('police', 'trend').length).to be_between(1, 14).inclusive
    expect(widgets.dig('permits', 'trend').length).to be_between(1, 30).inclusive
    expect(widgets.dig('crashes', 'trend').length).to be_between(1, 8).inclusive
    expect(widgets.dig('traffic_volume', 'trend').sum { |point| point['value'] }).to eq(1200)
    expect(widgets.dig('bicycle_counts', 'trend').sum { |point| point['value'] }).to eq(42)
    expect(widgets.dig('pedestrian_counts', 'weekday_heat').sum { |point| point['count'] }).to eq(900)
  end

  it 'anchors dashboard trends to source-covered time instead of today' do
    day = 24 * 60 * 60
    now = Time.now.utc
    source_time = now - (4 * day)
    Muni::Store.db[:service_requests].delete
    Muni::Store.db[:police_log_entrys].delete

    upsert_service_request('sr/source-window', opened_at: source_time, updated_at: source_time)
    upsert_police_log('pd/source-window', occurred_at: source_time - day, reported_at: source_time)
    Muni::Store.bump_seen('cambridge/service_requests', source_time)
    Muni::Store.bump_seen('cambridge/police_log', source_time)

    get '/api/dashboard?hall=cambridge'

    widgets = JSON.parse(last_response.body)['widgets']
    expect(widgets.dig('service_requests', 'opened_trend').last['date']).to eq(source_time.utc.strftime('%Y-%m-%d'))
    expect(widgets.dig('police', 'trend').last['date']).to eq(source_time.utc.strftime('%Y-%m-%d'))
    expect(widgets.dig('police', 'trend').sum { |point| point['value'] }).to eq(1)
  end

  it 'returns city dashboard accountability and source metadata' do
    seed_dashboard_records(Time.now.utc)
    Muni::Store.bump_seen('cambridge/service_requests', Time.now.utc)

    get '/api/dashboard?hall=cambridge'

    payload = JSON.parse(last_response.body)
    widgets = payload['widgets']
    sources = payload['sources']
    expect(widgets.dig('service_requests', 'resolution_trend').length).to be_between(1, 30).inclusive
    expect(widgets.dig('service_requests', 'resolution_trend').first['count']).to be_positive
    expect(widgets.dig('service_requests', 'avg_close_seconds')).to be_positive
    expect(widgets.dig('police', 'median_report_lag_seconds')).to be >= 0
    expect(widgets.dig('crashes', 'latest_data_lag_seconds')).to be >= 0
    service_source = sources.find { |source| source['category'] == 'service_requests' }
    expect_service_source_metadata(service_source)
    expect(sources.find { |source| source['category'] == 'police' }['note']).to include('not a citywide crime-rate')
  end

  it 'returns merged category records newest first' do
    Muni::Store.upsert(Muni::Records::ServiceRequest.new(
                         external_id: 'sr/old', hall: 'cambridge', case_type: 'Old',
                         status: 'Open', department: 'DPW', neighborhood: 'Area 4',
                         description: 'old', location: [-71.10, 42.31],
                         opened_at: Time.now.utc - 3600, source_url: 'https://example/old'
                       ))

    get '/api/category/service_requests/records?hall=cambridge&limit=10'
    expect(last_response).to be_ok
    rows = JSON.parse(last_response.body)
    expect(rows.first['external_id']).to eq('sr/1')
    expect(rows.first['_record_class']).to eq('Muni::Records::ServiceRequest')
  end
end
