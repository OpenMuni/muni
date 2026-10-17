require 'spec_helper'

RSpec.describe Muni::View do
  before { Muni.boot! }

  def source(slug)
    Muni::Registry.source(slug)
  end

  def metered_parking_geometry
    {
      'type'        => 'MultiPolygon',
      'coordinates' => [
        [
          [
            [-71.1101, 42.3699],
            [-71.1099, 42.3699],
            [-71.1099, 42.3701],
            [-71.1101, 42.3701],
            [-71.1101, 42.3699]
          ]
        ]
      ]
    }
  end

  def metered_parking_record(attrs = {})
    record_attrs = {
      external_id:      'metered-parking/A001',
      hall:             'cambridge',
      space_id:         'A001',
      max_minutes:      120,
      max_time_label:   '2 hours',
      hourly_rate:      2.0,
      rate_label:       '$2/hr',
      operation_hours:  '8:00AM-8:00PM',
      operation_window: '8 AM-8 PM',
      rule_status:      'rules_known',
      location:         [-71.11, 42.37],
      geometry:         metered_parking_geometry
    }.merge(attrs)
    Muni::Records::MeteredParkingSpace.new(**record_attrs)
  end

  def food_truck_record(external_id, attrs = {})
    record_attrs = {
      external_id: external_id,
      hall:        'cambridge',
      truck_name:  'Usable Truck',
      weekday:     'Monday',
      hours:       '11am-2pm',
      open_time:   '11:00 AM',
      close_time:  '2:00 PM',
      address:     '1 Main St',
      location:    [-71.1, 42.37],
      issued_at:   Time.utc(2026, 6, 1)
    }.merge(attrs)
    Muni::Records::FoodTruck.new(**record_attrs)
  end

  def park_geometry
    {
      'type'        => 'Polygon',
      'coordinates' => [[
        [-71.1002, 42.3600],
        [-71.1000, 42.3600],
        [-71.1000, 42.3602],
        [-71.1002, 42.3602],
        [-71.1002, 42.3600]
      ]]
    }
  end

  def park_record(external_id, attrs = {})
    record_attrs = {
      external_id: external_id,
      hall:        'cambridge',
      name:        'Dana Park',
      owner:       'City',
      park_type:   'City park',
      fcode:       1,
      acres:       1.4,
      location:    [-71.10012, 42.36008],
      geometry:    park_geometry
    }.merge(attrs)
    Muni::Records::Park.new(**record_attrs)
  end

  def upsert_digest_event(external_id, attrs = {})
    record_attrs = {
      external_id:    external_id,
      hall:           'cambridge',
      source_slug:    'cambridge/city_calendar',
      source_name:    'City Calendar',
      source_type:    'event_listing',
      item_type:      'event',
      title:          'Official event',
      summary:        'Official Cambridge event',
      category:       'events',
      url:            'https://example.test/event',
      event_start_at: Time.utc(2026, 6, 18, 22),
      event_end_at:   Time.utc(2026, 6, 19, 0),
      location_name:  'City Hall',
      tags:           ['events'],
      dedupe_key:     external_id,
      metadata:       {}
    }.merge(attrs)
    Muni::Store.upsert(Muni::Records::DigestItem.new(**record_attrs))
  end

  it 'derives category source slugs from the canonical get registry' do
    expect(described_class.sources_for(:police, 'cambridge')).to eq(['cambridge/police_log'])
    expect(described_class.find(:safety).section).to eq('Safety')
    expect(described_class.sources_for(:safety, 'cambridge')).to include(
      'cambridge/police_log',
      'cambridge/crime_reports',
      'cambridge/dispatch_calls',
      'cambridge/cpd_crash_log'
    )
    expect(described_class.find(:crashes).title).to eq('Collisions')
    expect(described_class.sources_for(:crashes, 'cambridge')).to eq(
      %w[cambridge/vision_zero_crashes cambridge/cpd_crash_log]
    )
    expect(described_class.sources_for(:recent_crashes, 'cambridge')).to eq(
      %w[cambridge/vision_zero_crashes cambridge/cpd_crash_log]
    )
    expect(described_class.primary_source(:crashes, 'cambridge')).to eq('cambridge/vision_zero_crashes')
  end

  it 'registers official events with future-facing filters' do
    category = described_class.find(:events)
    filters = described_class.category_filter_definitions(:events, 'cambridge')

    expect(category).to have_attributes(
      section:       'Events',
      title:         'Events',
      icon:          'calendar',
      empty_message: 'No official city events in this window.'
    )
    expect(described_class.sources_for(:events, 'cambridge')).to eq(
      %w[cambridge/city_calendar cambridge/tourism_events]
    )
    expect(filters.first).to include(
      name:    'time_range',
      default: 'upcoming',
      values:  %w[upcoming today tonight tomorrow 7d 30d],
      future:  true
    )
    expect(filters).to include(name: 'source_name', label: 'Source', field: :source_name)
    expect(filters).to include(name: 'location_name', label: 'Location', field: :location_name)
  end

  it 'owns timed filter definitions for current operational datasets' do
    filters = described_class.filter_definitions(source('cambridge/police_log'), :police)

    expect(filters.first).to include(name: 'time_range', label: 'Time', default: '7d')
    expect(filters).to include(name: 'crime_category', label: 'Category', field: :crime_category)
    expect(filters).to include(name: 'crime_subcategory', label: 'Case type', field: :crime_subcategory)
  end

  it 'defaults sparse permit records to the latest official batch window' do
    filters = described_class.filter_definitions(source('cambridge/building_permits'), :permits)

    expect(filters.first).to include(name: 'time_range', label: 'Time', default: 'latest',
                                     values: %w[latest 1d 2d 7d 14d 30d 90d], source_anchored: true)
  end

  it 'defaults 311 to the active service backlog' do
    filters = described_class.filter_definitions(source('cambridge/service_requests'), :service_requests)

    expect(filters.first).to include(name: 'time_range', label: 'Time', default: 'active',
                                     values: %w[active latest 1d 2d 7d 14d 30d 90d], source_anchored: true)
    expect(described_class.latest_window_seconds(:service_requests)).to eq(7 * 24 * 60 * 60)
  end

  it 'defaults sparse zoning appeals to the latest official batch window' do
    filters = described_class.filter_definitions(source('cambridge/zoning_appeals'), :zoning_appeals)

    expect(filters.first).to include(name: 'time_range', label: 'Time', default: 'latest',
                                     values: %w[latest 1d 2d 7d 14d 30d 90d])
  end

  it 'defaults delayed crash data to the latest official batch window' do
    filters = described_class.filter_definitions(source('cambridge/vision_zero_crashes'), :crashes)

    expect(filters.first).to include(name: 'time_range', label: 'Time', default: 'latest',
                                     values: %w[latest 1d 2d 7d 14d 30d 90d])
    expect(filters).to include(name: 'crash_status', label: 'Status',
                               synthetic: :crash_status, values: ['Fatal', 'Injury', 'No injury'])
  end

  it 'exposes category-level facets for multi-source safety overview' do
    filters = described_class.category_filter_definitions(:safety, 'cambridge')

    expect(filters.first).to include(name: 'time_range', label: 'Time', default: 'latest')
    expect(filters).to include(name: 'incident_kind', label: 'Kind', synthetic: :incident_kind,
                               values: ['Police log', 'Crime', 'Fire dispatch', 'Police dispatch', 'Recent crash'])
    expect(filters).to include(name: 'neighborhood', label: 'Neighborhood', field: :neighborhood)
  end

  it 'sorts crime reports by reported time before occurrence time' do
    older_reported = Muni::Records::CrimeReport.new(
      external_id:    'crime/older-reported',
      reported_at:    Time.utc(2026, 5, 12, 20),
      occurred_at:    Time.utc(2026, 12, 5, 20),
      crime_category: 'Larceny'
    )
    newer_reported = Muni::Records::CrimeReport.new(
      external_id:    'crime/newer-reported',
      reported_at:    Time.utc(2026, 5, 31, 20),
      occurred_at:    Time.utc(2026, 5, 1, 20),
      crime_category: 'Shoplifting'
    )

    expect(described_class.merge_rows([older_reported, newer_reported], 10).map(&:external_id)).to eq(
      %w[crime/newer-reported crime/older-reported]
    )
  end

  it 'serializes GeoJSON feature timestamps as ISO8601 strings' do
    record = Muni::Records::CrimeReport.new(
      external_id: 'crime/geo',
      reported_at: Time.utc(2026, 5, 31, 20),
      location:    [-71.1, 42.37]
    )

    feature = described_class.to_category_geojson([[record, 'cambridge/crime_reports']])[:features].first
    expect(feature.dig(:properties, :reported_at)).to eq('2026-05-31T20:00:00Z')
  end

  it 'does not add time filters to inventory sources' do
    filters = described_class.filter_definitions(source('cambridge/tree_inventory'), :trees)

    expect(filters.map { |definition| definition[:name] }).not_to include('time_range')
    expect(filters).to include(name: 'condition', label: 'Condition', field: :condition)
  end

  it 'registers Environment as an aggregate inventory category with Trees and Parks subcategories' do
    environment = described_class.find(:environment)
    filters = described_class.category_filter_definitions(:environment, 'cambridge')

    expect(environment).to have_attributes(
      section: 'Environment',
      title:   'Environment',
      icon:    'leaf'
    )
    expect(described_class.sources_for(:environment, 'cambridge')).to eq(
      %w[cambridge/tree_inventory cambridge/parks]
    )
    expect(described_class.sources_for(:parks, 'cambridge')).to eq(['cambridge/parks'])
    expect(filters.map { |definition| definition[:name] }).not_to include('time_range')
    expect(filters).to include(name: 'kind', label: 'Kind', synthetic: :environment_kind, values: %w[Trees Parks])
  end

  it 'treats parks as current inventory with park type and owner facets' do
    filters = described_class.filter_definitions(source('cambridge/parks'), :parks)

    expect(filters.map { |definition| definition[:name] }).not_to include('time_range')
    expect(filters).to include(name: 'park_type', label: 'Kind', field: :park_type)
    expect(filters).to include(name: 'owner', label: 'Owner', field: :owner)
  end

  it 'treats food trucks as current inventory with day and truck facets' do
    filters = described_class.filter_definitions(source('cambridge/food_trucks'), :food_trucks)

    expect(filters.map { |definition| definition[:name] }).not_to include('time_range')
    expect(filters).to include(name: 'weekday', label: 'Day', field: :weekday)
    expect(filters).to include(name: 'truck_name', label: 'Truck', field: :truck_name)
  end

  it 'treats metered parking as current inventory with advisory rule facets' do
    filters = described_class.filter_definitions(source('cambridge/metered_parking_spaces'), :parking)

    expect(filters.map { |definition| definition[:name] }).not_to include('time_range')
    expect(filters).to include(name: 'meter_status', label: 'Meter status',
                               synthetic: :parking_meter_status, values: Muni::Parking::STATUS_VALUES)
    expect(filters).to include(name: 'max_time', label: 'Max stay', field: :max_time_label)
    expect(filters).to include(name: 'rate', label: 'Rate', field: :rate_label)
    expect(filters).to include(name: 'operation_window', label: 'Hours', field: :operation_window)
  end

  it 'detects food truck rows open at the current Cambridge time' do
    now = Time.utc(2026, 6, 15, 16, 30) # Monday 12:30 PM EDT.
    open_truck = Muni::Records::FoodTruck.new(
      external_id: 'truck/open',
      hall:        'cambridge',
      weekday:     'Monday',
      open_time:   '11:00 AM',
      close_time:  '2:00 PM'
    )
    closed_truck = Muni::Records::FoodTruck.new(
      external_id: 'truck/closed',
      hall:        'cambridge',
      weekday:     'Monday',
      open_time:   '8:00 AM',
      close_time:  '11:00 AM'
    )

    pairs = [[open_truck, 'cambridge/food_trucks'], [closed_truck, 'cambridge/food_trucks']]

    expect(described_class.open_food_truck_pairs(pairs, now: now)).to eq([[open_truck, 'cambridge/food_trucks']])
  end

  it 'keeps only surfaceable food truck stops for public category views' do
    usable = food_truck_record('truck/usable')
    event_only = food_truck_record(
      'truck/event',
      truck_name: 'Event Truck', hours: 'As needed, for events', address: 'Various'
    )
    unknown_hours = food_truck_record(
      'truck/unknown',
      truck_name: 'Unknown Truck', hours: 'Unknown', open_time: nil, close_time: nil
    )

    pairs = [[event_only, 'cambridge/food_trucks'], [usable, 'cambridge/food_trucks'],
             [unknown_hours, 'cambridge/food_trucks']]

    expect(described_class.surfaceable_food_truck_pairs(pairs)).to eq([[usable, 'cambridge/food_trucks']])
  end

  it 'dedupes surfaceable food truck stops by truck, day, place, and time' do
    older = food_truck_record('truck/older', issued_at: Time.utc(2026, 5, 1))
    newer = food_truck_record('truck/newer', issued_at: Time.utc(2026, 6, 1))

    filtered = described_class.surfaceable_food_truck_pairs(
      [[older, 'cambridge/food_trucks'], [newer, 'cambridge/food_trucks']]
    )

    expect(filtered).to eq([[newer, 'cambridge/food_trucks']])
  end

  it 'applies synthetic crash status filters in the core view layer' do
    definition = described_class
                 .filter_definitions(source('cambridge/vision_zero_crashes'), :crashes)
                 .find { |filter| filter[:name] == 'crash_status' }

    where = described_class.apply_filter({}, definition, 'Injury')

    expect(where).to eq(injury: true, fatal: false)
  end

  it 'filters safety pairs by synthetic incident kind' do
    fire = Muni::Records::DispatchCall.new(external_id: 'dispatch/fire', hall: 'cambridge', agency: 'Fire')
    police = Muni::Records::DispatchCall.new(external_id: 'dispatch/police', hall: 'cambridge', agency: 'Police')
    crime = Muni::Records::CrimeReport.new(external_id: 'crime/1', hall: 'cambridge')

    pairs = [
      [fire, 'cambridge/dispatch_calls'],
      [police, 'cambridge/dispatch_calls'],
      [crime, 'cambridge/crime_reports']
    ]

    filtered = described_class.filter_pairs(pairs, incident_kind: 'Fire dispatch')

    expect(filtered).to eq([[fire, 'cambridge/dispatch_calls']])
  end

  it 'filters parking pairs by synthetic meter status' do
    known = metered_parking_record(external_id: 'metered-parking/known', space_id: 'KNOWN')
    unknown = metered_parking_record(external_id: 'metered-parking/unknown', space_id: 'UNKNOWN',
                                     rule_status: 'unknown_rules', max_minutes: nil, hourly_rate: nil)
    pairs = [
      [known, 'cambridge/metered_parking_spaces'],
      [unknown, 'cambridge/metered_parking_spaces']
    ]

    expect(described_class.filter_pairs(pairs, meter_status: 'Unknown rules'))
      .to eq([[unknown, 'cambridge/metered_parking_spaces']])
  end

  # rubocop:disable RSpec/ExampleLength, Layout/HashAlignment
  it 'returns default event records for today and future by overlap, source dedupe, and calendar sort' do
    Muni::Store.ensure_tables!
    allow(Time).to receive(:now).and_return(Time.utc(2026, 6, 18, 22)) # 6 PM Cambridge time.
    upsert_digest_event(
      'event/ongoing',
      title: 'Already Started',
      event_start_at: Time.utc(2026, 6, 18, 20, 30),
      event_end_at: Time.utc(2026, 6, 18, 22, 30),
      dedupe_key: 'ongoing'
    )
    upsert_digest_event(
      'event/city-duplicate',
      title: 'Shared Concert',
      event_start_at: Time.utc(2026, 6, 18, 22),
      event_end_at: Time.utc(2026, 6, 19, 0),
      dedupe_key: 'shared-concert'
    )
    upsert_digest_event(
      'event/tourism-duplicate',
      source_slug: 'cambridge/tourism_events',
      source_name: 'Cambridge Office for Tourism',
      title: 'Shared Concert',
      event_start_at: Time.utc(2026, 6, 18, 22),
      event_end_at: Time.utc(2026, 6, 19, 0),
      dedupe_key: 'shared-concert'
    )
    upsert_digest_event(
      'event/all-day',
      title: 'All Day Exhibit',
      event_start_at: Time.utc(2026, 6, 18, 4),
      event_end_at: Time.utc(2026, 6, 19, 4),
      dedupe_key: 'all-day',
      metadata: { 'all_day' => true }
    )
    upsert_digest_event(
      'event/tomorrow',
      title: 'Tomorrow Show',
      event_start_at: Time.utc(2026, 6, 19, 22),
      event_end_at: Time.utc(2026, 6, 20, 0),
      dedupe_key: 'tomorrow'
    )
    upsert_digest_event(
      'event/meeting',
      title: 'Board Meeting',
      item_type: 'public_meeting',
      event_start_at: Time.utc(2026, 6, 18, 22),
      event_end_at: Time.utc(2026, 6, 19, 0),
      dedupe_key: 'meeting'
    )

    rows = Muni::Data.category_records(slug: 'events', hall: 'cambridge', params: {}, limit: 10)
    ids = rows.map { |row| row[:external_id] || row['external_id'] }

    expect(ids.first).to eq('event/city-duplicate')
    expect(ids).to include('event/ongoing', 'event/all-day')
    expect(ids.index('event/tomorrow')).to be > ids.index('event/all-day')
    expect(ids).not_to include('event/tourism-duplicate', 'event/meeting')

    today_rows = Muni::Data.category_records(
      slug: 'events', hall: 'cambridge', params: { 'time_range' => 'today' }, limit: 10
    )
    today_ids = today_rows.map { |row| row[:external_id] || row['external_id'] }
    expect(today_ids).not_to include('event/tomorrow')
  end
  # rubocop:enable RSpec/ExampleLength, Layout/HashAlignment

  it 'serializes metered parking polygons as GeoJSON with centroid fallback properties' do
    geometry = metered_parking_geometry
    record = metered_parking_record(geometry: geometry)

    feature = described_class.to_category_geojson([[record, 'cambridge/metered_parking_spaces']])[:features].first

    expect(feature[:geometry]).to eq(geometry)
    expect(feature.dig(:properties, :location)).to eq([-71.11, 42.37])
    expect(feature.dig(:properties, 'meter_status')).to be_a(String)
    expect(feature[:properties]).not_to have_key(:geometry)
  end

  it 'serializes park polygons as GeoJSON with centroid fallback properties' do
    geometry = park_geometry
    record = park_record('parks/1', geometry: geometry)

    feature = described_class.to_category_geojson([[record, 'cambridge/parks']])[:features].first

    expect(feature[:geometry]).to eq(geometry)
    expect(feature.dig(:properties, :location)).to eq([-71.10012, 42.36008])
    expect(feature.dig(:properties, :name)).to eq('Dana Park')
    expect(feature[:properties]).not_to have_key(:geometry)
  end

  it 'filters Environment aggregate rows by synthetic kind' do
    tree = Muni::Records::Tree.new(external_id: 'tree/1', hall: 'cambridge', species_common: 'Red Maple',
                                   location: [-71.1, 42.36])
    park = park_record('parks/1')
    pairs = [[tree, 'cambridge/tree_inventory'], [park, 'cambridge/parks']]

    expect(described_class.filter_pairs(pairs, kind: 'Parks')).to eq([[park, 'cambridge/parks']])
    expect(described_class.filter_pairs(pairs, kind: 'Trees')).to eq([[tree, 'cambridge/tree_inventory']])
  end
end
