require 'spec_helper'

RSpec.describe Boston::SharedCkan do
  it 'normalizes both Boston 311 schemas to the shared service-request record' do
    source = Boston::ServiceRequests.new
    current = source.normalize_new_system(
      'case_id' => 'B-1', 'service_name' => 'Pothole', 'case_status' => 'OPEN',
      'assigned_department' => 'PWD', 'full_address' => '1 City Hall Sq',
      'open_date' => '2026-08-20T10:00:00', 'longitude' => '-71.0589', 'latitude' => '42.3601'
    )
    legacy = source.normalize_legacy(
      'case_enquiry_id' => 'B-2', 'type' => 'Street Light', 'case_status' => 'Closed',
      'open_dt' => '2026-01-02', 'closed_dt' => '2026-01-03',
      'longitude' => 'bad', 'latitude' => '42.36'
    )

    expect(current.to_h).to include(external_id: 'B-1', hall: 'boston', case_type: 'Pothole', status: 'Open')
    expect(source.class.incident_kind).to be_nil
    expect(current.location).to eq([-71.0589, 42.3601])
    expect(legacy.closed_at).not_to be_nil
    expect(legacy.location).to be_nil
  end

  it 'normalizes crime, crash, and fatality IDs without conflating incident kinds' do
    crime = Boston::CrimeReports.new.normalize(
      'INCIDENT_NUMBER' => 'I-1', 'OFFENSE_DESCRIPTION' => 'LARCENY',
      'OCCURRED_ON_DATE' => '2026-08-20T12:30:00', 'Long' => '-71.07', 'Lat' => '42.34'
    )
    crashes = Boston::VisionZeroCrashes.new
    crash = crashes.normalize_crash('_id' => 7, 'dispatch_ts' => '2026-08-20', 'mode_type' => 'Bike')
    fatality = crashes.normalize_fatality('_id' => 7, 'date_time' => '2026-08-21', 'mode_type' => 'Pedestrian')

    expect(crime).to have_attributes(hall: 'boston', crime_category: 'LARCENY')
    expect(crash.external_id).to eq('crash:7')
    expect(crash.cyclist).to be(true)
    expect(fatality.external_id).to eq('fatality:7')
    expect(fatality.fatal).to be(true)
  end

  it 'parses permits, money, parking policies, and inventory geometry' do
    permit = Boston::BuildingPermits.new.normalize(
      'permitnumber' => 'ALT-1', 'permittypedescr' => 'Alteration',
      'declared_valuation' => '$12,500.25', 'issued_date' => '2026-08-01',
      'x_longitude' => '-71.1', 'y_latitude' => '42.3'
    )
    meter = Boston::MeteredParkingSpaces.new.normalize(
      'METER_ID' => '450001', 'SPACE_NUMBER' => '1',
      'PAY_POLICY' => '08:00AM-08:00PM MON-SAT $0.25 120', 'BASE_RATE' => '0.25',
      'LONGITUDE' => '-71.07', 'LATITUDE' => '42.35', 'METER_STATE' => 'ACTIVE'
    )
    park = Boston::Parks.new.normalize(
      'OS_ID' => 'OS-1', 'SITE_NAME' => 'Test Park', 'ACRES' => '2.5',
      'shape_wkt' => 'POLYGON ((-71.1 42.3, -71.0 42.3, -71.0 42.4, -71.1 42.3))'
    )

    expect(permit.declared_valuation).to eq(12_500.25)
    expect(meter).to have_attributes(max_minutes: 120, max_time_label: '120 min', rate_label: '$0.25 base rate')
    expect(park.geometry['type']).to eq('Polygon')
    expect(park.location).not_to be_nil
  end

  it 'normalizes development and list-only zoning records' do
    development = Boston::DevelopmentProjects.new.normalize(
      'project_id' => 'A80-1', 'project__project_name' => 'Homes', 'total_residential_units' => '12'
    )
    zoning = Boston::ZoningAppeals.new.normalize('boa_apno' => 'BOA-1', 'address' => '1 Main St')

    expect(development.residential_units).to eq(12)
    expect(zoning.location).to be_nil
  end

  it 'normalizes trees, trucks, counts, work zones, and events' do
    tree = Boston::TreeInventory.new.normalize('id' => 'T-1', 'spp_com' => 'Elm', 'dbh' => '9.5')
    truck = Boston::FoodTrucks.new.normalize('_id' => 4, 'Day' => 'Monday', 'Truck' => 'Lunch', 'Location' => 'Plaza')
    count = Boston::BicycleCounts.new.normalize(
      'count_id' => 'C-1', 'date' => '2026-08-01', 'day_bikes' => '123',
      'long' => '-71.05', 'lat' => '42.35'
    )
    work = Boston::ConstructionHighlights.new.normalize('Permit' => 'W-1', 'Street' => 'Main', 'Status' => 'Active')
    event = Boston::CityCalendar.new.normalize(
      'App Number' => 'E-1', 'App Name' => 'Block Party',
      'Start Date and Time' => '2026-09-01 12:00:00', 'End Date and Time' => '2026-09-01 16:00:00'
    )

    expect(tree.diameter_in).to eq(9.5)
    expect(truck.weekday).to eq('Monday')
    expect(count.count).to eq(123)
    expect(work.source_slug).to eq('boston/construction_highlights')
    expect(event.event_start_at).not_to be_nil
  end
end
