require 'spec_helper'

RSpec.describe Cambridge do
  def stub_socrata(rows)
    fake_socrata = instance_double(Muni::Clients::Socrata, query: rows)
    allow(Muni::Clients::Socrata).to receive(:new).and_return(fake_socrata)
    fake_socrata
  end

  def stub_arcgis(features)
    fake_arcgis = instance_double(Muni::Clients::Arcgis, query_geojson: features)
    allow(Muni::Clients::Arcgis).to receive(:new).and_return(fake_arcgis)
    fake_arcgis
  end

  def stub_open311_pages(*pages)
    fake_http = instance_double(Muni::Helpers::Http)
    allow(Muni::Helpers::Http).to receive(:new)
      .with(base_url: 'https://seeclickfix.com/open311/v2/554', headers: {})
      .and_return(fake_http)
    allow(fake_http).to receive(:get) do |path, params|
      raise "unexpected Open311 path: #{path}" unless path == 'requests.json'

      pages[params.fetch('page').to_i - 1] || []
    end
    fake_http
  end

  def expected_cambridge_source_slugs
    %w[
      cambridge/bicycle_counts
      cambridge/service_requests
      cambridge/police_log
      cambridge/crime_reports
      cambridge/dispatch_calls
      cambridge/building_permits
      cambridge/new_construction_permits
      cambridge/development_log
      cambridge/zoning_appeals
      cambridge/vision_zero_crashes
      cambridge/cpd_crash_log
      cambridge/pedestrian_counts
      cambridge/traffic_volume_daily
      cambridge/tree_inventory
      cambridge/parks
      cambridge/food_trucks
      cambridge/metered_parking_spaces
      cambridge/city_news
      cambridge/city_calendar
      cambridge/tourism_events
      cambridge/primegov_meetings
      cambridge/meetings
      cambridge/cambridge_life
      cambridge/cambridge_day
      cambridge/construction_highlights
      cambridge/city_construction_projects
      cambridge/practical_services
    ]
  end

  def service_request_row
    {
      'ticket_id'                     => '14046744',
      'issue_type'                    => 'Bike Lane Obstruction',
      'issue_category'                => 'Street and Sidewalk',
      'ticket_status'                 => 'Open',
      'issue_description'             => 'Blocked bike lane',
      'ticket_created_date_time'      => '2023-02-08T11:35:58.000Z',
      'ticket_last_updated_date_time' => '2023-02-08T12:10:00.000Z',
      'acknowledged_at'               => '2023-02-08T11:45:00.000Z',
      'address'                       => 'Massachusetts Ave, Cambridge, MA',
      'lat'                           => '42.3630616031828',
      'lng'                           => '-71.0948129727191',
      'image'                         => 'https://example.test/image.jpg',
      'html_url'                      => { 'url' => 'https://seeclickfix.com/issues/14046744' }
    }
  end

  def open311_service_request_row(extra = {})
    {
      'service_request_id' => '22073259',
      'service_name'       => 'Missed Food Waste Pickup (Green Bin)',
      'status'             => 'open',
      'agency_responsible' => 'City of Cambridge',
      'description'        => 'Full compost bin was not collected',
      'address'            => '65 Prentiss St Cambridge 02140, United States',
      'lat'                => 42.38433938731057,
      'long'               => -71.1154859916978,
      'requested_datetime' => '2026-06-24T20:48:35-04:00',
      'updated_datetime'   => '2026-06-24T20:48:36-04:00',
      'media_url'          => 'https://example.test/photo.jpg'
    }.merge(extra)
  end

  def permit_row
    {
      'id'                           => '163348',
      'full_address'                 => '625 Massachusetts Ave, Cambridge, MA 02139',
      'status'                       => 'Active',
      'issue_date'                   => '2022-03-21T00:00:00.000Z',
      'detailed_description_of_work' => 'Add new rear entry',
      'total_cost'                   => '128235',
      'coordinates'                  => { 'coordinates' => [-71.103484, 42.365464] },
      'permit_type'                  => 'Building: Alteration and Addition',
      'applicant_submit_date'        => '2022-03-01T00:00:00.000Z',
      'proposed_property_use'        => 'Office',
      'mbl'                          => '123-45'
    }
  end

  def updated_crash_row
    {
      ':id'                  => 'row-bnwz.jhdw~kn5c',
      'date_time'            => '2026-05-31T10:18:00.000',
      'object_1'             => 'PASSENGER CAR',
      'street_number'        => '40',
      'street_name'          => 'GRANITE ST',
      'location'             => { 'latitude' => '42.35621', 'longitude' => '-71.1124' },
      'may_involve_cyclist'  => '1',
      'manner_of_collision'  => 'ANGLE',
      'first_harmful_event'  => 'COLLISION WITH PEDALCYCLE',
      'p2_injury'            => 'SUSPECTED MINOR INJURY',
      'p2_non_motorist_desc' => 'BICYCLIST'
    }
  end

  def crime_report_row
    {
      'file_number'             => '2009-01781',
      'date_of_report'          => '2009-03-11T13:00:00.000',
      'crime_date_time'         => '03/11/2009 11:00 - 13:00',
      'crime'                   => 'Larceny from MV',
      'reporting_area'          => '802',
      'neighborhood'            => 'Baldwin',
      'location'                => '1600 Massachusetts Ave, Cambridge, MA',
      'reporting_area_location' => { 'type' => 'Point', 'coordinates' => [-71.11777156, 42.37775382] }
    }
  end

  def dispatch_call_row
    {
      'type'             => 'BOX ALARM                                         ',
      'group'            => 'FIRE ALARM     ',
      'primaryagency'    => 'F',
      'address'          => '0XX ESSEX ST, Cambridge, MA',
      'intersection'     => '',
      'priority'         => '2',
      'datetimereceived' => '2026-05-31T23:20:23.000',
      'datetimeclosed'   => '2026-05-31T23:31:12.000',
      'reportingarea'    => '409',
      'firebox'          => '4241 ',
      'policesector'     => '2',
      'policeroute'      => '4R   ',
      'ladderdistrict'   => '3',
      'enginedistrict'   => '2',
      'neighborhood'     => 'AREA 4 (MID-E CAM)  ',
      'location_1'       => '0XX ESSEX ST, Cambridge, MA'
    }
  end

  def cpd_crash_row
    {
      'datetime'             => '2026-06-15T09:48:00.000',
      'intersection_street1' => 'CHANNING ST',
      'intersection_street2' => 'MT AUBURN',
      'motorists'            => '2.0',
      'cyclists'             => '0.0',
      'pedestrians'          => '1.0',
      'injuries'             => '2.0',
      'hospitalizations'     => '2.0',
      'neighborhood'         => 'West Cambridge'
    }
  end

  def traffic_volume_daily_row
    {
      'observed_on'  => '2026-06-16T00:00:00.000',
      'id'           => '452e4f7f-bb89-4e99-9924-13df40ef2735',
      'intersection' => 'Cambridge St at First Street and N. First Street',
      'class'        => 'Bus',
      'count'        => '3'
    }
  end

  def bicycle_count_row
    {
      'countlocation'    => 'Concord Ave & Garden St',
      'date'             => '2002-10-30T00:00:00.000',
      'time'             => '07:30:00',
      'street'           => 'Concord Ave',
      'trafficdirection' => 'Northwestbound',
      'cyclistlocation'  => 'Sidewalk',
      'cyclistdirection' => 'With Traffic',
      'movementtype'     => 'Right',
      'count'            => '1',
      'temperature'      => '40',
      'weather'          => 'Mostly cloudy',
      'nodenumber'       => '763',
      'latitude'         => '42.3783247779643',
      'longitude'        => '-71.1237087846876'
    }
  end

  def pedestrian_count_row
    {
      'date'         => '2022-03-18T00:00:00.000',
      'intersection' => 'Binney Street and Fulkerson Street',
      'count'        => '1425'
    }
  end

  def tree_row
    {
      'the_geom'   => { 'coordinates' => [-71.14031322306903, 42.375911660475985] },
      'treeid'     => '2427',
      'sitetype'   => 'Stump',
      'commonname' => 'Red Maple',
      'scientific' => 'Acer rubrum',
      'diameter'   => '12.5',
      'ownership'  => 'City',
      'plantdate'  => '2020-04-01T00:00:00.000Z',
      'order_'     => 'WO-1'
    }
  end

  def food_truck_row
    {
      'id'                             => '1207967',
      'status'                         => 'Complete',
      'applicant_submit_date'          => '2026-05-18T00:00:00.000',
      'issue_date'                     => '2026-05-20T00:00:00.000',
      'business_name'                  => 'Truth Juice LLC',
      'dba'                            => 'Truth Juice',
      'mobile_food_truck_name'         => 'Truth Juice On The Run',
      'items_to_be_sold'               => "Juice\nsmoothies",
      'equipment'                      => "Refrigerator\nsink",
      'refrigeration_method'           => 'Mechanical',
      'soft_serve_machine'             => 'No',
      'food_protection_certification'  => '2027-05-20T00:00:00.000',
      'allergen_awareness'             => '2027-05-21T00:00:00.000',
      'hours_of_operation_monday'      => '8:00am - 8:00pm',
      'location_of_food_truck_monday'  => '1151 Massachusetts Ave., Cambridge MA 02138',
      'hours_of_operation_tuesday'     => 'TBD',
      'location_of_food_truck_tuesday' => 'TBD',
      'location_off_site_food_prep'    => '1151 Massachusetts Ave., Cambridge MA 02138',
      'location_of_toilet_facilities'  => 'On site',
      'food_handler_count'             => '2',
      'sanitizer_type'                 => 'Quat',
      'viewpoint_id'                   => '1207967',
      'attestat_date'                  => '2026-05-18T00:00:00.000',
      'business_address'               => '1151 Massachusetts Ave., Cambridge MA 02138'
    }
  end

  def metered_parking_row
    {
      'space_id'   => 'A001',
      'pbyp_zone'  => '1234',
      'maxtime'    => '2 Hours',
      'minutesper' => '7.5',
      'rate'       => '$2.00',
      'operationh' => '8:00AM-8:00PM (Mon-Sat)',
      'smartmeter' => 'Y',
      'the_geom'   => {
        'type'        => 'MultiPolygon',
        'coordinates' => [
          [
            [
              [-71.1000, 42.3600],
              [-71.1002, 42.3600],
              [-71.1002, 42.3602],
              [-71.1000, 42.3602],
              [-71.1000, 42.3600]
            ]
          ]
        ]
      }
    }
  end

  def park_feature(attrs = {})
    properties = {
      'OBJECTID'         => 3,
      'JOIN_ID'          => 6,
      'FCODE'            => 21,
      'NAME'             => 'Alewife Brook Reservation',
      'OWNER'            => 'State',
      'OSCODE'           => 24,
      'RCODE'            => 6,
      'Acres'            => 1.7,
      'last_edited_date' => 1_774_387_062_000
    }.merge(attrs.delete(:properties) || {})
    geometry = if attrs.key?(:geometry)
                 attrs.delete(:geometry)
               else
                 {
                   'type'        => 'Polygon',
                   'coordinates' => [[
                     [-71.1102, 42.3698],
                     [-71.1098, 42.3698],
                     [-71.1098, 42.3702],
                     [-71.1102, 42.3702],
                     [-71.1102, 42.3698]
                   ]]
                 }
               end
    { 'type' => 'Feature', 'properties' => properties, 'geometry' => geometry }.merge(attrs)
  end

  def new_construction_row
    {
      'id'                         => '19116',
      'full_address'               => '111 First St, Cambridge, MA 02141',
      'status'                     => 'Active',
      'applicant_submit_date'      => '2018-08-17T00:00:00.000Z',
      'issue_date'                 => '2019-09-03T00:00:00.000Z',
      'proposed_building_use'      => 'Commercial / Mixed Use',
      'construction_type'          => 'Type 1A',
      'proposed_count_of_dwelling' => '118',
      'gross_square_footage'       => '500,000',
      'total_cost_of_construction' => '$42,019,744',
      'description_of_work'        => 'New mixed-use building',
      'mbl'                        => '10-67',
      'coordinates'                => { 'coordinates' => [-71.077841, 42.367361] }
    }
  end

  def development_project_row
    {
      'project_id'          => '142',
      'project_name'        => 'Cambridge Crossing Block X',
      'address'             => '100 North First St',
      'status'              => 'Under Construction',
      'primary_use'         => 'Residential',
      'project_type'        => 'PUD',
      'residential_units'   => '120',
      'affordable_units'    => '40',
      'total_gfa'           => '299,954',
      'far'                 => '3.5',
      'developer'           => 'DivcoWest',
      'neighborhood'        => 'East Cambridge',
      'year_complete'       => '2026',
      'project_description' => 'Mixed residential building',
      'latitude'            => '42.3724',
      'longitude'           => '-71.0827'
    }
  end

  def zoning_appeal_row
    {
      'id'                             => '144871',
      'full_address'                   => '17 Dudley St, Cambridge, MA 02140',
      'status'                         => 'Complete',
      'current_use'                    => 'Residential - 3 Family',
      'proposed_use'                   => 'Residential-3 Family',
      'zoning_district'                => 'Residential B Zone',
      'variance_relief_description'    => 'Relief from setback requirements',
      'requested_no_of_dwelling_units' => '3',
      'applicant_submit_date'          => '2021-09-16T00:00:00.000Z',
      'variance_hearing_deadline'      => '2022-01-13T00:00:00.000Z',
      'issue_date'                     => '2022-02-11T00:00:00.000Z',
      'coordinates'                    => { 'coordinates' => [-71.130092, 42.396356] }
    }
  end

  describe Cambridge::ServiceRequests do
    it 'registers only Cambridge launch sources and matching beats' do
      slugs = Muni::Registry.sources.keys.grep(%r{\Acambridge/})
      expect(slugs).to match_array(expected_cambridge_source_slugs)
      expect(Muni::Registry.beats.keys.grep(%r{\Acambridge/})).to match_array(
        slugs + %w[
          cambridge/analytics
          cambridge/digest
          cambridge/meetings_summary
          cambridge/primegov_meeting_records
          cambridge/service_request_lifecycle
        ]
      )
      expect(Muni::Registry.beat('cambridge/primegov_meetings').every_seconds).to eq(3_600)
      expect(Muni::Registry.beat('cambridge/primegov_meetings').mode).to eq(:full)
      expect(Muni::Registry.beat('cambridge/primegov_meetings').limit).to eq(250)
      expect(Muni::Registry.beat('cambridge/primegov_meeting_records').every_seconds).to eq(3_600)
      expect(Muni::Registry.beat('cambridge/meetings').every_seconds).to eq(21_600)
    end

    it 'normalizes Open311 request rows' do
      stub_open311_pages([open311_service_request_row], [])

      record = described_class.new.pull.first
      expect(record.to_h).to include(
        external_id: '22073259',
        case_type:   'Missed Food Waste Pickup (Green Bin)',
        status:      'Open',
        department:  'City of Cambridge',
        description: 'Full compost bin was not collected',
        address:     '65 Prentiss St Cambridge 02140, United States',
        location:    [-71.1154859916978, 42.38433938731057],
        opened_at:   Time.utc(2026, 6, 25, 0, 48, 35),
        updated_at:  Time.utc(2026, 6, 25, 0, 48, 36),
        closed_at:   nil,
        image_url:   'https://example.test/photo.jpg',
        source_url:  'https://seeclickfix.com/issues/22073259'
      )
    end

    it 'paginates Open311 rows until the feed is empty' do
      fake_http = stub_open311_pages(
        [open311_service_request_row('service_request_id' => '1')],
        [open311_service_request_row('service_request_id' => '2')],
        []
      )

      records = described_class.new.pull(limit: 10)

      expect(records.map(&:external_id)).to eq(%w[1 2])
      expect(fake_http).to have_received(:get).exactly(3).times
    end

    it 'stops Open311 pagination when the configured limit is reached' do
      fake_http = stub_open311_pages(
        [
          open311_service_request_row('service_request_id' => '1'),
          open311_service_request_row('service_request_id' => '2')
        ],
        [open311_service_request_row('service_request_id' => '3')]
      )

      records = described_class.new.pull(limit: 2)

      expect(records.map(&:external_id)).to eq(%w[1 2])
      expect(fake_http).to have_received(:get).once
    end

    it 'sets closed_at from Open311 updated_datetime for closed rows' do
      row = open311_service_request_row(
        'status'           => 'closed',
        'updated_datetime' => '2026-06-24T16:44:58-04:00'
      )
      stub_open311_pages([row])

      record = described_class.new.pull.first

      expect(record.status).to eq('Closed')
      expect(record.closed_at).to eq(Time.utc(2026, 6, 24, 20, 44, 58))
    end

    it 'falls back to Socrata when Open311 is unavailable' do
      fake_http = stub_open311_pages([])
      allow(fake_http).to receive(:get).and_raise(Muni::Helpers::Http::Error.new(503, 'unavailable'))
      stub_socrata([service_request_row])

      record = described_class.new.pull.first
      expect(record.external_id).to eq('14046744')
      expect(record.case_type).to eq('Street and Sidewalk')
      expect(record.address).to eq('Massachusetts Ave, Cambridge, MA')
      expect(record.location).to eq([-71.0948129727191, 42.3630616031828])
      expect(record.acknowledged_at).to eq(Time.utc(2023, 2, 8, 11, 45))
      expect(record.updated_at).to eq(Time.utc(2023, 2, 8, 12, 10))
      expect(record.image_url).to eq('https://example.test/image.jpg')
      expect(record.source_url).to eq('https://seeclickfix.com/issues/14046744')
    end
  end

  describe Cambridge::PoliceLog do
    it 'normalizes daily log rows into list-friendly records' do
      fake = [{
        'date_time'    => '2025-03-06T01:07:00.000',
        'id'           => '25001925',
        'type'         => 'INCIDENT',
        'subtype'      => 'LARCENY FROM BUILDING C266 S20',
        'location'     => 'NEWPORT RD',
        'description'  => 'Police responded and took a report.',
        'last_updated' => '2025-03-11T09:35:52.000'
      }]
      stub_socrata(fake)

      resolver = ->(label) { label == 'NEWPORT RD' ? [-71.1201, 42.3881] : nil }
      record = described_class.new(location_resolver: resolver).pull.first
      expect(record.external_id).to eq('25001925')
      expect(record.crime_category).to eq('INCIDENT')
      expect(record.crime_subcategory).to eq('LARCENY FROM BUILDING C266 S20')
      expect(record.neighborhood).to eq('NEWPORT RD')
      expect(record.location).to eq([-71.1201, 42.3881])
      expect(record.source_url).to eq('https://data.cambridgema.gov/Public-Safety/Daily-Police-Log/3gki-wyrb')
    end
  end

  describe Cambridge::CrimeReports do
    it 'uses the newer cursor instead of expanding back to the retention floor' do
      fake_socrata = stub_socrata([])
      since = Time.now.utc - (7 * 86_400)

      described_class.new.pull(since: since, limit: 10)

      expect(fake_socrata).to have_received(:query).with(
        hash_including(where: include(Muni::Helpers::Normalize.sql_timestamp(since)))
      )
    end

    it 'normalizes official crime report rows to reporting-area points' do
      stub_socrata([crime_report_row])

      record = described_class.new.pull.first

      expect(record.external_id).to eq('2009-01781')
      expect(record.crime_category).to eq('Larceny from MV')
      expect(record.reporting_area).to eq('802')
      expect(record.neighborhood).to eq('Baldwin')
      expect(record.location_description).to eq('1600 Massachusetts Ave, Cambridge, MA')
      expect(record.location).to eq([-71.11777156, 42.37775382])
      expect(record.occurred_at).to eq(Time.local(2009, 3, 11, 11).utc)
      expect(record.reported_at).to eq(Time.utc(2009, 3, 11, 17))
    end
  end

  describe Cambridge::DispatchCalls do
    it 'normalizes masked CAD rows without inventing precise coordinates' do
      stub_socrata([dispatch_call_row])
      resolver = ->(label) { label.include?('ESSEX') ? [-71.098, 42.365] : nil }

      record = described_class.new(location_resolver: resolver).pull.first

      expect(record.external_id).to start_with('dispatch/')
      expect(record.agency).to eq('Fire')
      expect(record.incident_type).to eq('BOX ALARM')
      expect(record.incident_group).to eq('FIRE ALARM')
      expect(record.neighborhood).to eq('AREA 4 (MID-E CAM)')
      expect(record.location_description).to eq('0XX ESSEX ST, Cambridge, MA')
      expect(record.location).to eq([-71.098, 42.365])
      expect(record.received_at).to eq(Time.utc(2026, 6, 1, 3, 20, 23))
    end
  end

  describe Cambridge::LocationResolver do
    it 'does not use public Nominatim unless explicitly enabled' do
      original_env = ENV.to_h
      ENV.delete('MUNI_NOMINATIM_URL')
      ENV.delete('MUNI_ENABLE_PUBLIC_NOMINATIM')

      census = instance_double(Muni::Helpers::Http)
      allow(census).to receive(:get).and_return({ 'result' => { 'addressMatches' => [] } })
      allow(Muni::Helpers::Http).to receive(:new).and_call_original

      expect(described_class.new(census: census).call('UNKNOWN ST')).to be_nil
      expect(Muni::Helpers::Http).not_to have_received(:new).with(base_url: described_class::NOMINATIM_BASE)
    ensure
      ENV.replace(original_env)
    end

    it 'uses an explicitly configured Nominatim-compatible service' do
      original_env = ENV.to_h
      ENV['MUNI_NOMINATIM_URL'] = 'https://geo.example.test'

      census = instance_double(Muni::Helpers::Http)
      nominatim = instance_double(Muni::Helpers::Http)
      allow(census).to receive(:get).and_return({ 'result' => { 'addressMatches' => [] } })
      allow(nominatim).to receive(:get).and_return([{ 'lon' => '-71.1', 'lat' => '42.37' }])
      allow(Muni::Helpers::Http).to receive(:new).with(base_url: 'https://geo.example.test').and_return(nominatim)

      expect(described_class.new(census: census).call('UNKNOWN ST')).to eq([-71.1, 42.37])
      expect(Muni::Helpers::Http).to have_received(:new).with(base_url: 'https://geo.example.test')
    ensure
      ENV.replace(original_env)
    end
  end

  describe Cambridge::BuildingPermits do
    it 'normalizes permit coordinates and description from current fields' do
      stub_socrata([permit_row])

      record = described_class.new.pull.first
      expect(record.description).to eq('Add new rear entry')
      expect(record.location).to eq([-71.103484, 42.365464])
      expect(record.declared_valuation).to eq(128_235.0)
      expect(record.applied_at).to eq(Time.utc(2022, 3, 1))
      expect(record.proposed_use).to eq('Office')
      expect(record.mbl).to eq('123-45')
    end
  end

  describe Cambridge::VisionZeroCrashes do
    include WebMock::API

    it 'queries Socrata with a floating_timestamp-safe where clause' do
      since = Time.now.utc - (30 * 86_400)
      stub = stub_request(:get, %r{data\.cambridgema\.gov/resource/.+\.json})
             .with(query: hash_including('$where' => "date_time >= '#{Muni::Helpers::Normalize.sql_timestamp(since)}'"))
             .to_return(status: 200, body: '[]', headers: { 'Content-Type' => 'application/json' })

      described_class.new.pull(since: since)
      expect(stub).to have_been_requested
    end

    it 'normalizes historical crash coordinates when present' do
      fake = [{
        'crash_number' => '23669',
        'date_time'    => '2010-01-08T19:30:00.000',
        'object_1'     => 'Auto',
        'object_2'     => 'Parked Vehicle',
        'location'     => 'Shepard St & Cambridge, MA',
        'coordinates'  => { 'coordinates' => [-71.12, 42.38] }
      }]
      stub_socrata(fake)

      record = described_class.new.pull.first
      expect(record.crash_type).to eq('Auto / Parked Vehicle')
      expect(record.location_description).to eq('Shepard St & Cambridge, MA')
      expect(record.location).to eq([-71.12, 42.38])
    end

    it 'normalizes the updated official crash feed fields' do
      stub_socrata([updated_crash_row])

      record = described_class.new.pull.first
      expect(record.external_id).to eq('row-bnwz.jhdw~kn5c')
      expect(record.crash_type).to eq('COLLISION WITH PEDALCYCLE')
      expect(record.location_description).to eq('40 / GRANITE ST')
      expect(record.location).to eq([-71.1124, 42.35621])
      expect(record.injury).to be(true)
      expect(record.cyclist).to be(true)
    end

    it 'ignores text-only crash location values when coordinates are absent' do
      fake = [{
        'crash_number' => '1600000815',
        'date_time'    => '2016-06-30T15:00:00.000',
        'object_1'     => 'PASSENGER CAR',
        'location'     => "MNSR O'BRIEN HIGHWAY"
      }]
      stub_socrata(fake)

      record = described_class.new.pull.first
      expect(record.external_id).to eq('1600000815')
      expect(record.location_description).to eq("MNSR O'BRIEN HIGHWAY")
      expect(record.location).to be_nil
    end
  end

  describe Cambridge::CpdCrashLog do
    it 'normalizes the fresh CPD crash log as a separate record type' do
      stub_socrata([cpd_crash_row])
      resolver = ->(label) { label.include?('CHANNING') ? [-71.12, 42.37] : nil }

      record = described_class.new(location_resolver: resolver).pull.first

      expect(record.external_id).to start_with('cpd-crash/')
      expect(record.location_description).to eq('CHANNING ST / MT AUBURN')
      expect(record.neighborhood).to eq('West Cambridge')
      expect(record.motorists).to eq(2)
      expect(record.pedestrians).to eq(1)
      expect(record.injury).to be(true)
      expect(record.location).to eq([-71.12, 42.37])
    end
  end

  describe Cambridge::TrafficVolumeDaily do
    it 'normalizes Miovision daily rollups rather than raw movement rows' do
      stub_socrata([traffic_volume_daily_row])
      resolver = ->(label) { label.include?('Cambridge St') ? [-71.08, 42.37] : nil }

      record = described_class.new(location_resolver: resolver).pull.first

      expect(record.external_id).to include('traffic-volume/')
      expect(record.intersection_id).to eq('452e4f7f-bb89-4e99-9924-13df40ef2735')
      expect(record.vehicle_class).to eq('Bus')
      expect(record.count).to eq(3)
      expect(record.observed_at).to eq(Time.utc(2026, 6, 16, 4))
    end
  end

  describe Cambridge::BicycleCounts do
    it 'normalizes citywide bicycle count rows with official coordinates' do
      stub_socrata([bicycle_count_row])

      record = described_class.new.pull.first

      expect(record.count_location).to eq('Concord Ave & Garden St')
      expect(record.count).to eq(1)
      expect(record.weather).to eq('Mostly cloudy')
      expect(record.location).to eq([-71.1237087846876, 42.3783247779643])
      expect(record.observed_at).to eq(Time.utc(2002, 10, 30, 12, 30))
    end
  end

  describe Cambridge::PedestrianCounts do
    it 'normalizes daily pedestrian count rows' do
      stub_socrata([pedestrian_count_row])
      resolver = ->(label) { label.include?('Binney') ? [-71.089, 42.368] : nil }

      record = described_class.new(location_resolver: resolver).pull.first

      expect(record.external_id).to start_with('ped-count/')
      expect(record.intersection).to eq('Binney Street and Fulkerson Street')
      expect(record.count).to eq(1425)
      expect(record.location).to eq([-71.089, 42.368])
    end
  end

  describe Cambridge::TreeInventory do
    it 'normalizes current street tree species fields' do
      fake_socrata = stub_socrata([tree_row])

      record = described_class.new.pull.first
      expect(fake_socrata).to have_received(:query).with(resource: described_class::RESOURCE,
                                                         order:    'treeid ASC',
                                                         limit:    100,
                                                         offset:   0)
      expect(record.species_common).to eq('Red Maple')
      expect(record.species_scientific).to eq('Acer rubrum')
      expect(record.condition).to eq('Stump')
      expect(record.ownership).to eq('City')
      expect(record.plant_date).to eq(Time.utc(2020, 4, 1))
      expect(record.order_number).to eq('WO-1')
      expect(record.location).to eq([-71.14031322306903, 42.375911660475985])
    end

    it 'infers blank site type as tree only for current tree-shaped rows' do
      stub_socrata([
                     tree_row.merge('treeid' => 'MIT-1', 'sitetype' => nil, 'ownership' => 'MIT'),
                     tree_row.merge('treeid' => 'SITE-1', 'sitetype' => nil, 'commonname' => nil,
                                    'scientific' => nil, 'ownership' => 'City')
                   ])

      records = described_class.new.pull

      expect(records.find { |record| record.external_id == 'MIT-1' }.condition).to eq('Tree')
      expect(records.find { |record| record.external_id == 'SITE-1' }.condition).to eq('Unclassified site')
      expect(records.find { |record| record.external_id == 'MIT-1' }.ownership).to eq('MIT')
    end
  end

  describe Cambridge::FoodTrucks do
    it 'normalizes official mobile food truck permit schedules into truck-day records' do
      stub_socrata([food_truck_row])
      resolver = ->(label) { label.include?('1151 Massachusetts') ? [-71.1135, 42.3721] : nil }

      records = described_class.new(location_resolver: resolver).pull
      record = records.first

      expect(records.length).to eq(1)
      expect(record.external_id).to include('food-truck/1207967/20260520/monday')
      expect(record.truck_name).to eq('Truth Juice On The Run')
      expect(record.business_name).to eq('Truth Juice LLC')
      expect(record.weekday).to eq('Monday')
      expect(record.hours).to eq('8:00am - 8:00pm')
      expect(record.open_time).to eq('8:00 AM')
      expect(record.close_time).to eq('8:00 PM')
      expect(record.address).to eq('1151 Massachusetts Ave., Cambridge MA 02138')
      expect(record.location).to eq([-71.1135, 42.3721])
    end

    it 'parses common shorthand food truck hour ranges' do
      row = food_truck_row.merge(
        'hours_of_operation_monday'      => '11a-8p',
        'hours_of_operation_tuesday'     => '12-7',
        'location_of_food_truck_tuesday' => '1151 Massachusetts Ave., Cambridge MA 02138'
      )
      stub_socrata([row])
      resolver = ->(label) { label.include?('1151 Massachusetts') ? [-71.1135, 42.3721] : nil }

      records = described_class.new(location_resolver: resolver).pull

      expect(records.find { |record| record.weekday == 'Monday' }.to_h).to include(
        open_time:  '11:00 AM',
        close_time: '8:00 PM'
      )
      expect(records.find { |record| record.weekday == 'Tuesday' }.to_h).to include(
        open_time:  '12:00 PM',
        close_time: '7:00 PM'
      )
    end

    it 'normalizes food truck business and permit details' do
      stub_socrata([food_truck_row])
      resolver = ->(label) { label.include?('1151 Massachusetts') ? [-71.1135, 42.3721] : nil }

      record = described_class.new(location_resolver: resolver).pull.first

      expect(record.items_to_be_sold).to eq('Juice, smoothies')
      expect(record.equipment).to eq('Refrigerator, sink')
      expect(record.food_handler_count).to eq(2)
      expect(record.business_address).to eq('1151 Massachusetts Ave., Cambridge MA 02138')
      expect(record.prep_location).to eq('1151 Massachusetts Ave., Cambridge MA 02138')
      expect(record.toilet_facilities).to eq('On site')
      expect(record.issued_at).to eq(Time.utc(2026, 5, 20))
      expect(record.food_protection_certification_expires_at).to eq(Time.utc(2027, 5, 20))
      expect(record.source_url).to eq('https://data.cambridgema.gov/d/qweb-m8r8')
    end

    it 'keeps vague official stop text without inventing map coordinates' do
      row = food_truck_row.merge(
        'location_of_food_truck_monday' => 'Various Cambridge locations',
        'hours_of_operation_monday'     => '9am-5pm'
      )
      stub_socrata([row])
      resolver = instance_double(Proc)

      record = described_class.new(location_resolver: resolver).pull.first

      expect(record.address).to eq('Various Cambridge locations')
      expect(record.location).to be_nil
    end
  end

  describe Cambridge::MeteredParkingSpaces do
    it 'queries the newer official metered parking spaces dataset with explicit fields' do
      fake_socrata = stub_socrata([metered_parking_row])

      described_class.new.pull(limit: 5_000)

      expect(fake_socrata).to have_received(:query).with(
        resource: described_class::RESOURCE,
        select:   described_class::SELECT,
        where:    'space_id IS NOT NULL AND the_geom IS NOT NULL',
        order:    'space_id ASC',
        limit:    5_000
      )
    end

    it 'normalizes metered parking rules and preserves polygon geometry' do
      stub_socrata([metered_parking_row])

      record = described_class.new.pull.first

      expect(record.to_h).to include(
        external_id:         'metered-parking/A001',
        space_id:            'A001',
        pay_by_phone_zone:   '1234',
        max_minutes:         120,
        max_time_label:      '2 hours',
        hourly_rate:         2.0,
        rate_label:          '$2/hr',
        minutes_per_payment: 7.5,
        operation_hours:     '8:00AM-8:00PM (Mon-Sat)',
        operation_window:    '8 AM-8 PM',
        rule_status:         'rules_known',
        smart_meter:         'Y'
      )
      expect(record.geometry).to eq(metered_parking_row['the_geom'])
      expect(record.location[0]).to be_within(0.00001).of(-71.10008)
      expect(record.location[1]).to be_within(0.00001).of(42.36008)
      expect(record.source_url).to eq('https://data.cambridgema.gov/Transportation/Metered-Parking-Spaces/kvrt-t8v3')
    end

    it 'skips rows without a space id or usable geometry' do
      stub_socrata([
                     metered_parking_row,
                     metered_parking_row.merge('space_id' => nil),
                     metered_parking_row.merge('space_id' => 'A002', 'the_geom' => nil)
                   ])

      records = described_class.new.pull

      expect(records.map(&:space_id)).to eq(['A001'])
    end
  end

  describe Cambridge::Parks do
    it 'queries the official ArcGIS open-space layer for public park FCODEs' do
      fake_arcgis = stub_arcgis([park_feature])

      described_class.new.pull(limit: 2_000)

      expect(fake_arcgis).to have_received(:query_geojson).with(
        path:       described_class::LAYER_PATH,
        where:      described_class::WHERE,
        out_fields: described_class::OUT_FIELDS,
        out_sr:     4326,
        limit:      2_000
      )
    end

    it 'normalizes public park polygons and preserves geometry' do
      stub_arcgis([park_feature])

      record = described_class.new.pull.first

      expect(record.to_h).to include(
        external_id: 'parks/6',
        hall:        'cambridge',
        name:        'Alewife Brook Reservation',
        owner:       'State',
        park_type:   'DCR/state park',
        fcode:       21,
        oscode:      24,
        rcode:       6,
        acres:       1.7
      )
      expect(record.edited_at).to eq(Time.at(1_774_387_062).utc)
      expect(record.geometry).to eq(park_feature['geometry'])
      expect(record.location[0]).to be_within(0.00001).of(-71.11004)
      expect(record.location[1]).to be_within(0.00001).of(42.36996)
      expect(record.source_url).to eq('https://gis.cambridgema.gov/arcgis/rest/services/CDDBasemap/MapServer/348')
    end

    it 'skips rows without a stable id or usable polygon geometry' do
      stub_arcgis([
                    park_feature,
                    park_feature(properties: { 'JOIN_ID' => nil, 'OBJECTID' => nil, 'FCODE' => 21 }),
                    park_feature(geometry: nil)
                  ])

      records = described_class.new.pull

      expect(records.map(&:external_id)).to eq(['parks/6'])
    end
  end

  describe Cambridge::NewConstructionPermits do
    it 'parses currency strings, dwelling units, and coordinates' do
      stub_socrata([new_construction_row])

      record = described_class.new.pull.first
      expect(record.external_id).to eq('19116')
      expect(record.status).to eq('Active')
      expect(record.proposed_use).to eq('Commercial / Mixed Use')
      expect(record.dwelling_units).to eq(118)
      expect(record.gross_square_footage).to eq(500_000.0)
      expect(record.declared_valuation).to eq(42_019_744.0)
      expect(record.issued_at).to eq(Time.utc(2019, 9, 3))
      expect(record.location).to eq([-71.077841, 42.367361])
      expect(record.mbl).to eq('10-67')
      expect(record.source_url).to eq('https://data.cambridgema.gov/d/9qm7-wbdc')
    end
  end

  describe Cambridge::DevelopmentLog do
    it 'normalizes project units, GFA, and lon/lat coordinates' do
      stub_socrata([development_project_row])

      record = described_class.new.pull.first
      expect(record.external_id).to eq('142')
      expect(record.name).to eq('Cambridge Crossing Block X')
      expect(record.status).to eq('Under Construction')
      expect(record.residential_units).to eq(120)
      expect(record.affordable_units).to eq(40)
      expect(record.gross_floor_area).to eq(299_954.0)
      expect(record.far).to eq(3.5)
      expect(record.year_complete).to eq(2026)
      expect(record.location).to eq([-71.0827, 42.3724])
    end
  end

  describe Cambridge::ZoningAppeals do
    it 'normalizes use, zoning district, relief, and hearing dates' do
      stub_socrata([zoning_appeal_row])

      record = described_class.new.pull.first
      expect(record.external_id).to eq('144871')
      expect(record.status).to eq('Complete')
      expect(record.current_use).to eq('Residential - 3 Family')
      expect(record.zoning_district).to eq('Residential B Zone')
      expect(record.relief).to eq('Relief from setback requirements')
      expect(record.dwelling_units_requested).to eq(3)
      expect(record.applied_at).to eq(Time.utc(2021, 9, 16))
      expect(record.hearing_deadline_at).to eq(Time.utc(2022, 1, 13))
      expect(record.decided_at).to eq(Time.utc(2022, 2, 11))
      expect(record.location).to eq([-71.130092, 42.396356])
    end
  end

  describe Cambridge::CityNews do
    it 'normalizes official news result cards into digest items' do
      stub_request(:get, 'https://www.cambridgema.gov/news').to_return(
        status:  200,
        body:    <<~HTML,
          <main><ul class="news-listing"><li>
            <h3><a href="/news/coolingcenters">Cooling Centers Open Today</a></h3>
            <span>6/17/2026</span>
            <p>The City opened cooling centers during the heat advisory.</p>
          </li></ul></main>
        HTML
        headers: { 'Content-Type' => 'text/html' }
      )

      record = described_class.new.pull.first

      expect(record.source_slug).to eq('cambridge/city_news')
      expect(record.source_type).to eq('official_record')
      expect(record.title).to eq('Cooling Centers Open Today')
      expect(record.url).to eq('https://www.cambridgema.gov/news/coolingcenters')
      expect(record.category).to eq('civic update')
    end
  end

  # rubocop:disable RSpec/ExampleLength, Layout/HashAlignment
  describe Cambridge::CityCalendar do
    it 'normalizes iCalendar meetings with local event times' do
      stub_request(:get, 'https://www.cambridgema.gov/citycalendar.ics').to_return(
        status: 200,
        body:   <<~ICS,
          BEGIN:VCALENDAR
          BEGIN:VEVENT
          UID:meeting-1
          DTSTART;TZID=America/New_York:20260617T093000
          DTEND;TZID=America/New_York:20260617T103000
          SUMMARY:Board of Assessors Public Meeting
          DESCRIPTION:Board of Assessors Public Meeting
          LOCATION:Online\\, Cambridge
          URL:https://www.cambridgema.gov/citycalendar/event
          END:VEVENT
          END:VCALENDAR
        ICS
        headers: { 'Content-Type' => 'text/calendar' }
      )

      record = described_class.new.pull.first

      expect(record.item_type).to eq('public_meeting')
      expect(record.section_hint).to eq('civic_decisions')
      expect(record.event_start_at).to eq(Time.utc(2026, 6, 17, 13, 30))
      expect(record.location_name).to include('Online')
    end

    it 'parses all-day events, folded descriptions, categories, and cleaned locations' do
      stub_request(:get, 'https://www.cambridgema.gov/citycalendar.ics').to_return(
        status: 200,
        body:   <<~ICS,
          BEGIN:VCALENDAR
          BEGIN:VEVENT
          UID:nature-1
          DTSTART;VALUE=DATE:20260618
          DTEND;VALUE=DATE:20260619
          SUMMARY:CPL Nature Club
          DESCRIPTION:Outdoor story time with hands-on activi
           ties and nature games.
          LOCATION:Main Library<br />449 Broadway
          CATEGORIES:Library,Kids
          URL:/citycalendar/nature
          END:VEVENT
          END:VCALENDAR
        ICS
        headers: { 'Content-Type' => 'text/calendar' }
      )

      record = described_class.new.pull.first

      expect(record.item_type).to eq('event')
      expect(record.event_start_at).to eq(Time.utc(2026, 6, 18, 4))
      expect(record.event_end_at).to eq(Time.utc(2026, 6, 19, 4))
      expect(record.summary).to include('activities and nature games')
      expect(record.location_name).to eq('Main Library, 449 Broadway')
      expect(record.metadata['all_day']).to be(true)
      expect(record.metadata['categories']).to eq(%w[Library Kids])
    end
  end

  describe Cambridge::TourismEvents do
    def tourism_event_row(attrs = {})
      {
        'id'             => 101,
        'global_id'      => 'global-101',
        'title'          => 'River Festival',
        'description'    => '<p>Music and family activities.</p>',
        'url'            => 'https://cambridgeusa.org/event/river-festival/',
        'rest_url'       => 'https://cambridgeusa.org/wp-json/tribe/events/v1/events/101',
        'start_date'     => '2026-06-18 18:00:00',
        'end_date'       => '2026-06-18 20:00:00',
        'utc_start_date' => '2026-06-18 18:00:00',
        'utc_end_date'   => '2026-06-18 20:00:00',
        'timezone'       => 'UTC+0',
        'modified_utc'   => '2026-06-01 12:00:00',
        'all_day'        => false,
        'cost'           => 'Free',
        'image'          => { 'url' => 'https://example.test/river.jpg' },
        'categories'     => [{ 'name' => 'Music' }],
        'tags'           => [{ 'name' => 'Family' }],
        'venue'          => {
          'venue'  => 'Cambridge Common',
          'address' => 'Garden St',
          'city'    => 'Cambridge',
          'state'   => 'MA',
          'zip'     => '02138'
        }
      }.merge(attrs)
    end

    it 'paginates the REST API and keeps only Cambridge-specific events' do
      stub_request(:get, 'https://cambridgeusa.org/wp-json/tribe/events/v1/events')
        .with(query: hash_including('page' => '1'))
        .to_return(status: 200, body: JSON.dump('events' => [
                                                  tourism_event_row,
                                                  tourism_event_row(
                                                    'id' => 102,
                                                    'global_id' => 'global-102',
                                                    'title' => 'Boston Harbor Walk',
                                                    'venue' => {
                                                      'venue' => 'Museum of Science',
                                                      'address' => '1 Science Park',
                                                      'city' => 'Boston',
                                                      'state' => 'MA'
                                                    }
                                                  )
                                                ], 'total_pages' => 2),
                   headers: { 'Content-Type' => 'application/json' })
      stub_request(:get, 'https://cambridgeusa.org/wp-json/tribe/events/v1/events')
        .with(query: hash_including('page' => '2'))
        .to_return(status: 200, body: JSON.dump('events' => [
                                                  tourism_event_row(
                                                    'id' => 103,
                                                    'global_id' => 'global-103',
                                                    'title' => 'Harvard Square Walk',
                                                    'venue' => {
                                                      'venue' => 'Harvard Square',
                                                      'address' => 'Harvard Square'
                                                    }
                                                  )
                                                ], 'total_pages' => 2),
                   headers: { 'Content-Type' => 'application/json' })

      resolver = ->(_label) { [-71.1189, 42.3736] }
      records = described_class.new(location_resolver: resolver).pull(limit: 200)

      expect(records.map(&:title)).to eq(['River Festival', 'Harvard Square Walk'])
      expect(records.map(&:title)).not_to include('Boston Harbor Walk')
      festival = records.first
      expect(festival.event_start_at).to eq(Time.utc(2026, 6, 18, 22))
      expect(festival.category).to eq('music')
      expect(festival.tags).to include('tourism', 'music', 'family')
      expect(festival.metadata['cost']).to eq('Free')
      expect(festival.metadata['image_url']).to eq('https://example.test/river.jpg')
    end
  end
  # rubocop:enable RSpec/ExampleLength, Layout/HashAlignment

  describe Cambridge::PrimegovMeetings do
    def stub_primegov_upcoming(rows)
      stub_request(:get, 'https://cambridgema.primegov.com/api/v2/PublicPortal/ListUpcomingMeetings')
        .to_return(status: 200, body: JSON.dump(rows))
    end

    def stub_primegov_archive_years(*years)
      stub_request(:get, 'https://cambridgema.primegov.com/api/v2/PublicPortal/GetArchivedMeetingYears')
        .to_return(status: 200, body: JSON.dump(years.flatten))
    end

    def stub_primegov_archive(year, rows = [])
      stub_request(:get, "https://cambridgema.primegov.com/api/v2/PublicPortal/ListArchivedMeetings?year=#{year}")
        .to_return(status: 200, body: JSON.dump(rows))
    end

    def stub_primegov_empty_current_archives
      current_year = Time.now.year
      previous_year = current_year - 1
      stub_primegov_archive_years(current_year, previous_year)
      stub_primegov_archive(current_year)
      stub_primegov_archive(previous_year)
    end

    def primegov_document(id:, template_id:, output_type:, name:, published_at: '2026-06-20T12:00:00')
      {
        id:                id,
        templateId:        template_id,
        compileOutputType: output_type,
        publishDate:       published_at,
        templateName:      name
      }
    end

    def primegov_row(id:, title:, date:, time:, documents:, public_comment: false)
      {
        id:                 id,
        title:              title,
        date:               date,
        time:               time,
        allowPublicComment: public_comment,
        documentList:       documents
      }
    end

    def primegov_compiled_url(template_id, output_type: 1)
      "https://cambridgema.primegov.com/Public/CompiledDocument?meetingTemplateId=#{template_id}&compileOutputType=#{output_type}"
    end

    def expect_primegov_document(record, attrs)
      expect(record.metadata['documents']).to include(include(attrs))
    end

    it 'normalizes PrimeGov API meeting rows with public comment metadata' do
      documents = [
        primegov_document(id: 10, template_id: 11_371, output_type: 3, name: 'HTML Agenda'),
        primegov_document(id: 11, template_id: 11_371, output_type: 1, name: 'Agenda')
      ]
      stub_primegov_upcoming([
                               primegov_row(id: 1, title: 'City Council Meeting', date: 'Jun 22, 2026',
                                            time: '05:30 PM', documents: documents, public_comment: true)
                             ])
      stub_primegov_empty_current_archives

      record = described_class.new.pull.first

      expect(record.source_slug).to eq('cambridge/primegov_meetings')
      expect(record.section_hint).to eq('civic_decisions')
      expect(record.metadata['public_comment']).to be(true)
      expect(record.title).to eq('City Council Meeting')
      expect(record.event_start_at).to eq(Time.utc(2026, 6, 22, 21, 30))
      expect_primegov_document(
        record,
        'name' => 'Agenda', 'kind' => 'agenda', 'format' => 'pdf', 'url' => primegov_compiled_url(11_371)
      )
    end

    it 'allows explicit future dates for upcoming public meetings' do
      future_year = Time.now.year + 1
      parsed = described_class.new.send(:local_date_time, "Jan 12, #{future_year}", '05:30 PM')

      expect(parsed.year).to eq(future_year)
    end

    it 'pulls current and previous year archives with post-meeting documents' do
      current_year = Time.now.year
      previous_year = current_year - 1
      documents = [
        primegov_document(id: 20, template_id: 2163, output_type: 1, name: 'Minutes'),
        primegov_document(id: 21, template_id: 2177, output_type: 1, name: 'Final Actions')
      ]
      archived_row = primegov_row(id: 2, title: 'Regular City Council Meeting', date: "Jan 12, #{current_year}",
                                  time: '05:30 PM', documents: documents)
      stub_primegov_upcoming([])
      stub_primegov_archive_years(current_year, previous_year, previous_year - 1)
      current_archive = stub_primegov_archive(current_year, [archived_row])
      previous_archive = stub_primegov_archive(previous_year)

      record = described_class.new.pull(limit: 10).find { |row| row.external_id == 'cambridge/primegov_meetings/2' }

      expect(current_archive).to have_been_requested
      expect(previous_archive).to have_been_requested
      expect(record.metadata['archived']).to be(true)
      expect(record.metadata['documents']).to include(
        include('name' => 'Minutes', 'kind' => 'minutes', 'format' => 'pdf'),
        include('name' => 'Final Actions', 'kind' => 'final_actions', 'format' => 'pdf')
      )
    end
  end

  describe Cambridge::CambridgeLife do
    it 'normalizes official publication metadata' do
      stub_request(:get, 'https://www.cambridgema.gov/digital/publications').to_return(
        status: 200,
        body:   <<~HTML
          <main><article class="publication">
            <h2><a href="/digital/publications/cambridgelifespring2026">Cambridge Life - Spring 2026</a></h2>
            <p>Spring 2026</p>
            <p>Our latest issue explores parks and open spaces.</p>
          </article></main>
        HTML
      )

      record = described_class.new.pull.first

      expect(record.source_slug).to eq('cambridge/cambridge_life')
      expect(record.item_type).to eq('civic_life_story')
      expect(record.published_at).to eq(Time.utc(2026, 4, 1))
    end
  end

  describe Cambridge::CambridgeDay do
    it 'normalizes press feed metadata without article bodies' do
      stub_request(:get, 'https://www.cambridgeday.com/feed/').to_return(
        status: 200,
        body:   <<~XML
          <rss version="2.0"><channel><title>Cambridge Day</title><item>
            <title>Union rallies outside School Committee</title>
            <link>https://www.cambridgeday.com/2026/06/17/union-rally/</link>
            <description><![CDATA[<figure><img src="photo.jpg"/></figure>Ongoing contract negotiations serve as a backdrop.]]></description>
            <pubDate>Wed, 17 Jun 2026 12:00:00 GMT</pubDate>
            <category>Government</category>
          </item></channel></rss>
        XML
      )

      record = described_class.new.pull.first

      expect(record.source_type).to eq('press_report')
      expect(record.summary).to eq('Ongoing contract negotiations serve as a backdrop.')
      expect(record.metadata['copyright_scope']).to eq('headline_excerpt_only')
    end
  end

  describe Cambridge::ConstructionHighlights do
    it 'does not use future civic page dates for non-upcoming sources' do
      future_year = Time.now.year + 1

      parsed = described_class.new.send(:local_date_time, "Jan 12, #{future_year}")

      expect(parsed).to be_nil
    end

    it 'clamps yearless future page dates to the previous year' do
      parsed = described_class.new.send(:parse_date, 'November 18')

      expect(parsed).to eq(Date.new(Time.now.year - 1, 11, 18))
    end

    it 'normalizes weekly street-level construction impacts' do
      stub_request(:get, 'https://www.cambridgema.gov/departments/publicworks/cityprojects/weeklyconstructionhighlights')
        .to_return(
          status: 200,
          body:   <<~HTML
            <main><article class="construction-highlight">
              <h3><a href="/departments/publicworks/project">Mass Ave utility work</a></h3>
              <p>Construction on Mass Ave will require a detour near Central Square.</p>
            </article></main>
          HTML
        )

      record = described_class.new.pull.first

      expect(record.section_hint).to eq('street_level_impacts')
      expect(record.category).to eq('construction')
      expect(record.tags).to include('street impact')
    end
  end

  describe Cambridge::CityConstructionProjects do
    it 'normalizes active city construction project metadata' do
      stub_request(:get, 'https://www.cambridgema.gov/Departments/publicworks/cityprojects').to_return(
        status: 200,
        body:   <<~HTML
          <main><article class="project">
            <h3><a href="/departments/publicworks/project/riverstreet">River Street Reconstruction</a></h3>
            <p>Street and sidewalk reconstruction project near River Street.</p>
          </article></main>
        HTML
      )

      record = described_class.new.pull.first

      expect(record.source_slug).to eq('cambridge/city_construction_projects')
      expect(record.item_type).to eq('construction_project')
      expect(record.url).to include('riverstreet')
    end
  end

  describe Cambridge::PracticalServices do
    it 'normalizes citywide service reminders without address-specific guesses' do
      stub_request(:get, 'https://www.cambridgema.gov/services/streetcleaning').to_return(
        status: 200,
        body:   '<main><p>Juneteenth Friday June 19th: Street Cleaning rescheduled to June 29th</p></main>'
      )
      stub_request(:get, 'https://www.cambridgema.gov/services/curbsidecollections').to_return(
        status: 200,
        body:   '<main><p>Weekly Collections: One day behind schedule following a holiday.</p></main>'
      )
      stub_request(:get, 'https://www.cambridgema.gov/subscribe').to_return(
        status: 200,
        body:   '<main><a href="/subscribe#AlertsReminders">Street Cleaning Alerts</a></main>'
      )

      records = described_class.new.pull

      expect(records.map(&:section_hint)).to all(eq('practical_reminders'))
      expect(records.map(&:location_name).compact).to be_empty
      expect(records.map(&:title)).to include('Street Cleaning Alerts')
    end
  end
end
