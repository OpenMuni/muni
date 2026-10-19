# SQL call expectations verify that oversized public queries do not materialize all rows.
# rubocop:disable RSpec/ExampleLength, RSpec/MessageSpies
require 'spec_helper'

RSpec.describe Muni::ServiceRequestQuery do
  let(:now) { Time.utc(2026, 10, 18, 18) }

  before do
    allow(Time).to receive(:now).and_return(now)
    Muni::Hall.load_all!
    Muni::Store.ensure_tables!
    Muni::EfficiencyIndexes.prepare!
  end

  def insert(id, **attrs)
    defaults = { hall: 'cambridge', external_id: id, opened_at: now - 100, status: 'Open', location: [-71.1, 42.37] }
    Muni::Store.upsert(Muni::Records::ServiceRequest.new(**defaults, **attrs))
  end

  def query(params = {})
    Muni::Data::Query.new({ 'hall' => 'cambridge' }.merge(params)).service_request_query
  end

  it 'matches deployed Ruby visibility, including contradictory closure fields and normalization' do
    states = [
      { status: 'Open' }, { status: nil }, { status: 'Error' },
      { status: ' Closed ', updated_at: now - 10 }, { status: "\tCLOSED\n", updated_at: now - 400_000 },
      { status: 'Acknowledged', updated_at: now - 2_000_000 },
      { status: 'Closed', closed_at: now - 400_000, updated_at: now },
      { status: 'Open', closed_at: now - 400_000 }, { status: 'Archived', closed_at: now - 259_200 },
      { status: 'Closed', updated_at: nil }, { status: 'Closed', closed_at: now - 259_201 }
    ]
    states.each_with_index { |attrs, index| insert(index.to_s, **attrs) }
    expected = Muni::Store.query(Muni::Records::ServiceRequest, hall: 'cambridge')
                          .select do |row|
      Muni::ServiceRequestPolicy.visible?(row,
                                          now: now)
    end.map(&:external_id)
    expect(query.page[:items].map { |row| row[:external_id] }).to match_array(expected)
  end

  it 'retains explicit historical time filters and time_field behavior' do
    insert('closed', status: 'Closed', opened_at: now - 100, updated_at: now - 400_000)
    expect(query.page[:items]).to be_empty
    expect(query('history_view' => '1').page[:items].map { |row| row[:external_id] }).to eq(['closed'])
    expect(query('time_range' => '7d').page[:items].length).to eq(1)
    expect(query('time_field' => 'opened_at', 'time_range' => '7d').page[:items].length).to eq(1)
  end

  it 'pages deterministically with duplicate timestamps and nullable primary dates' do
    12.times { |index| insert(format('%02d', index)) }
    insert('fallback', opened_at: nil, updated_at: now - 200)
    ids = []
    cursor = nil
    loop do
      page = query('cursor' => cursor, 'limit' => '3').page
      ids.concat(page[:items].map { |row| row[:external_id] })
      cursor = page[:next_cursor]
      break unless cursor
    end
    expect(ids).to eq((0..11).map { |index| format('%02d', index) }.reverse + ['fallback'])
    expect(ids.uniq).to eq(ids)
  end

  it 'rejects malformed and cross-filter cursors' do
    3.times { |index| insert(index.to_s) }
    cursor = query('limit' => '1').page[:next_cursor]
    expect { query('cursor' => cursor, 'status' => 'Closed') }.to raise_error(described_class::Invalid)
    expect { query('cursor' => 'garbage') }.to raise_error(described_class::Invalid)
    expect { query('cursor' => ['bad']) }.to raise_error(described_class::Invalid)
    data = JSON.parse(Base64.urlsafe_decode64(cursor))
    data['last'][0] = 'not a timestamp'
    malformed = Base64.urlsafe_encode64(JSON.generate(data))
    expect { query('cursor' => malformed) }.to raise_error(described_class::Invalid)
  end

  it 'bounds hydration and honors legacy requested limits without exposing descriptions in compact pages' do
    250.times { |index| insert(index.to_s, description: 'detail') }
    expect(Muni::Store).to receive(:hydrate).exactly(20).times.and_call_original
    page = query('limit' => '20').page
    expect(page[:items].length).to eq(20)
    expect(page[:items].first).not_to have_key(:description)
    expect(page[:has_more]).to be(true)
  end

  it 'does not deduplicate identical external IDs from different halls' do
    insert('same')
    insert('same', hall: 'boston')
    records = Muni::Data::Query.new.service_request_query(sources: %w[cambridge/service_requests
                                                                      boston/service_requests]).page[:items]
    expect(records.map { |row| row[:hall] }).to match_array(%w[cambridge boston])
  end

  it 'requires a completed projection, then returns every eligible located ticket as an individual point' do
    1_200.times { |index| insert(index.to_s) }
    insert('invalid', location: nil)
    expect { query('bbox' => '-71.2,42.3,-71.0,42.5').map }.to raise_error(Muni::ServiceRequestMap::Incomplete)
    Muni::ServiceRequestMap.rebuild!
    expect(Muni::Store).not_to receive(:hydrate)
    map = query('bbox' => '-71.2,42.3,-71.0,42.5').map
    expect(map[:represented_count]).to eq(1_200)
    expect(map[:features].length).to eq(1_200)
    expect(map[:features].map { |feature| feature[:properties][:external_id] }.uniq.length).to eq(1_200)
    expect(map[:features].all? { |feature| feature[:properties][:map_signal] == 'open' }).to be(true)
    expect(map[:features].none? { |feature| feature[:properties].key?(:cluster) }).to be(true)
  end

  it 'pages the same eligible viewport requests shown as dots' do
    7.times { |index| insert(index.to_s) }
    insert('old', opened_at: now - (31 * 86_400))
    insert('closed', status: 'Closed')
    insert('elsewhere', location: [-71.3, 42.37])
    Muni::ServiceRequestMap.rebuild!
    params = { 'bbox' => '-71.2,42.3,-71.0,42.5' }
    map_ids = query(params).map[:features].map { |feature| feature[:properties][:external_id] }
    first = query(params.merge('map_view' => '1', 'limit' => '3')).page
    second = query(params.merge('map_view' => '1', 'limit' => '3', 'cursor' => first[:next_cursor])).page
    third = query(params.merge('map_view' => '1', 'limit' => '3', 'cursor' => second[:next_cursor])).page
    expect((first[:items] + second[:items] + third[:items]).map { |row| row[:external_id] }).to match_array(map_ids)
    expect(map_ids.length).to eq(7)
    expect { query('map_view' => '1').page }.to raise_error(described_class::Invalid)
    expect { query('bbox' => 'NaN,0,1,2').map }.to raise_error(described_class::Invalid)
  end

  it 'resumes an interrupted projection and maintains accepted geometry changes and deletions' do
    3.times { |index| insert(index.to_s) }
    expect(Muni::ServiceRequestMap.rebuild!(batch_size: 1, max_batches: 1)).to be(false)
    expect(Muni::ServiceRequestMap.ready?).to be(false)
    expect(Muni::ServiceRequestMap.rebuild!(batch_size: 1)).to be(true)
    insert('0', location: nil, updated_at: now)
    expect(Muni::Store.db[:service_request_map_points].where(external_id: '0').count).to eq(0)
    expect(Muni::Store.find(Muni::Records::ServiceRequest, '0', hall: 'cambridge').location).to be_nil
    Muni::Store.delete_before(Muni::Records::ServiceRequest, :opened_at, now, hall: 'cambridge')
    expect(Muni::Store.db[:service_request_map_points].count).to eq(0)
    expect(Muni::ServiceRequestMap.rebuild!).to be(true)
  end

  it 'does not change projection geometry for a rejected stale update' do
    insert('stale', updated_at: now)
    insert('stale', updated_at: now - 1_000, location: [-71.05, 42.36])
    expect(Muni::Store.db[:service_request_map_points].where(external_id: 'stale').get(:lon)).to eq(-71.1)
  end

  it 'excludes polygon holes, invalid coordinates and out-of-viewport points and rebuilds changed boundaries' do
    hall = Muni::Hall.find('cambridge')
    polygon = { 'type' => 'Polygon', 'coordinates' => [
      [[-72, 42], [-70, 42], [-70, 44], [-72, 44], [-72, 42]],
      [[-71.5, 42.5], [-71.2, 42.5], [-71.2, 42.8], [-71.5, 42.8], [-71.5, 42.5]]
    ] }
    allow(hall).to receive(:boundary).and_return(polygon)
    insert('inside', location: [-71.8, 43])
    insert('hole', location: [-71.3, 42.6])
    insert('outside', location: [-69, 43])
    insert('invalid', location: [200, 95])
    insert('west-edge', location: [-72, 43])
    insert('east-edge', location: [-70, 43])
    insert('north-edge', location: [-71, 44])
    insert('south-edge', location: [-71, 42])
    Muni::ServiceRequestMap.rebuild!
    map = query('bbox' => '-72,42,-70,44').map
    expect(map[:represented_count]).to eq(5) # all four viewport edges are included; cells remain disjoint
    expect(query.page[:items].length).to eq(8)
    allow(hall).to receive(:boundary).and_return(nil)
    expect(Muni::ServiceRequestMap.ready?).to be(false)
    Muni::ServiceRequestMap.rebuild!
    expect(Muni::ServiceRequestMap.ready?).to be(true)
    expect(query('bbox' => '-72,42,-70,44').map[:represented_count]).to eq(6)
  end

  it 'freezes source-anchored window cutoffs between pages even when newer records arrive' do
    4.times { |index| insert("old-#{index}", opened_at: now - index) }
    first = query('time_range' => 'latest', 'limit' => '2').page
    insert('newer', opened_at: now + 40_000_000)
    second = query('time_range' => 'latest', 'limit' => '2', 'cursor' => first[:next_cursor]).page
    expect((first[:items] + second[:items]).map { |row| row[:external_id] }).to match_array(%w[old-0 old-1 old-2 old-3])
  end

  it 'enforces both page ceilings and returns a well-formed empty page' do
    expect(query.page).to eq(items: [], has_more: false, next_cursor: nil)
    601.times { |index| insert(index.to_s) }
    expect(query('limit' => '9999').page[:items].length).to eq(200)
    expect(query('limit' => '9999').page(compact: false, maximum: 500)[:items].length).to eq(500)
  end

  it 'requires the covering projection index for readiness' do
    Muni::ServiceRequestMap.rebuild!
    expect(Muni::ServiceRequestMap.ready?).to be(true)
    Muni::Store.db.drop_index(:service_request_map_points, nil, name: :service_request_map_cover)
    expect(Muni::ServiceRequestMap.ready?).to be(false)
    Muni::EfficiencyIndexes.prepare!
    expect(Muni::ServiceRequestMap.ready?).to be(true)
  end

  it 'uses the covering map index before point lookups and the ordering index for lists' do
    Muni::ServiceRequestMap.rebuild!
    builder = query('bbox' => '-71.2,42.3,-71,42.5')
    filtered = builder.send(:filtered_dataset, map: true)
    map = builder.send(:within_viewport, filtered, source_first: true).select(Sequel[:service_requests][:external_id])
    plan = Muni::Store.db.fetch("EXPLAIN QUERY PLAN #{map.sql}").all
    expect(plan.first[:detail]).to include('COVERING INDEX service_requests_lifecycle_map_filters')
    expect(plan[1][:detail]).to include('COVERING INDEX service_request_map_cover')
    sql = "SELECT hall, external_id FROM service_requests WHERE hall='boston' " \
          'ORDER BY efficiency_sort_at DESC, external_id DESC LIMIT 201'
    order = Muni::Store.db.fetch("EXPLAIN QUERY PLAN #{sql}").all
    expect(order.first[:detail]).to include('service_requests_efficiency_order')
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MessageSpies
