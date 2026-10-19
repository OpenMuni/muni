# Source reconciliation tests use explicit request expectations across several source types.
# rubocop:disable RSpec/ExampleLength, RSpec/MessageSpies, RSpec/StubbedMock, RSpec/VerifiedDoubles
require 'spec_helper'
require 'muni/service_request_reconciliation'

RSpec.describe Muni::ServiceRequestReconciliation do
  let(:now) { Time.utc(2026, 10, 18, 20) }

  before do
    allow(Time).to receive(:now).and_return(now)
    Muni::Hall.load_all!
    Muni::Store.ensure_tables!
    Muni::EfficiencyIndexes.prepare!
  end

  def ticket(id = '1', **attrs)
    Muni::Records::ServiceRequest.new(hall: 'cambridge', external_id: id, status: 'Open',
                                      opened_at: now - 60, updated_at: now - 60,
                                      location: [-71.1, 42.37], **attrs)
  end

  def map(params = {})
    Muni::ServiceRequestMap.rebuild!
    Muni::Data::Query.new({ 'hall' => 'cambridge', 'bbox' => '-71.2,42.3,-71.0,42.5' }.merge(params))
                     .service_request_query.map
  end

  it 'hides old, closed, conflicting, unknown, missing and future reports before aggregation, without deleting' do
    attrs = [
      {}, { opened_at: now - (30 * 86_400) }, { opened_at: now - (30 * 86_400) - 0.000001 },
      { opened_at: nil }, { opened_at: now + 1 }, { status: 'Archived', closed_at: nil },
      { status: 'Open', closed_at: now }, { status: 'Closed' }, { status: nil }, { status: 'Error' },
      { status: 'In Progress', updated_at: now - (20 * 86_400) }
    ]
    attrs.each_with_index { |values, index| Muni::Store.upsert(ticket(index.to_s, **values)) }
    Muni::Store.db[:service_requests].insert(hall: 'cambridge', external_id: 'invalid', status: 'Open',
                                             opened_at: '2026-10-invalid')
    result = map('time_range' => 'all', 'time_field' => 'collected_at')
    expect(result[:represented_count]).to eq(3)
    expect(result[:features].sum { |feature| feature[:properties][:point_count] || 1 }).to eq(3)
    expect(Muni::Store.db[:service_requests].count).to eq(12)
    expect(Muni::Store.find(Muni::Records::ServiceRequest, '2', hall: 'cambridge')).not_to be_nil
    Muni::Store.db[:service_requests].where(hall:        'cambridge',
                                            external_id: '0').update(lifecycle_source_state: 'closed')
    expect(map[:represented_count]).to eq(2)
  end

  it 'applies closure precedence to the display as well as the lifecycle' do
    result = Muni::ServiceRequestPolicy.enrich(ticket(status: 'Acknowledged', updated_at: now - 2_000_000,
                                                      closed_at: now).to_h)
    expect(result).to include(display_status: 'closed', lifecycle_status: 'closed', map_visible: false)
  end

  it 'assigns map colors without treating age or a missing update as closure' do
    signal = ->(**attrs) { Muni::ServiceRequestPolicy.map_signal(ticket(**attrs), now: now) }
    expect(signal.call(status: 'Open')).to eq('open')
    expect(signal.call(status: 'In Progress')).to eq('acknowledged')
    expect(signal.call(status: 'Pending')).to eq('other_active')
    stale = signal.call(status: 'Open', opened_at: now - (20 * 86_400), updated_at: now - (15 * 86_400))
    expect(stale).to eq('no_recent_update')
    expect(signal.call(status: 'Closed')).to be_nil
    expect(signal.call(status: 'Open', opened_at: now - (31 * 86_400))).to be_nil
  end

  it 'rejects impossible report dates and local times instead of rolling them into valid map dates' do
    %w[2026-02-30T12:00:00Z 2026-10-18T24:00:00Z 2026-10-18T12:61:00Z invalid].each do |value|
      expect(Muni::ServiceRequestPolicy.reported_time(value)).to be_nil
    end
    expect(Muni::ServiceRequestPolicy.reported_time('2026-03-08T02:30:00', city: 'cambridge')).to be_nil
    expect(Muni::ServiceRequestPolicy.reported_time('2026-08-31 23:30:11.493000+00:00'))
      .to eq(Time.iso8601('2026-08-31T23:30:11.493000Z'))
    expect(Muni::ServiceRequestPolicy.reported_time('2026-08-31 23:30:11.493000+00'))
      .to eq(Time.iso8601('2026-08-31T23:30:11.493000Z'))
  end

  it 'normalizes actual Boston short UTC offsets and floating legacy lifecycle dates independently of host TZ' do
    source = Boston::ServiceRequests.new
    record = source.normalize_new_system('case_id' => 'BCS-00305557', 'case_status' => 'Closed',
                                         'open_date' => '2026-08-31 23:30:11.493000+00',
                                         'close_date' => '2026-09-02 07:29:02+00')
    expect(record.opened_at).to eq(Time.iso8601('2026-08-31T23:30:11.493000Z'))
    expect(record.closed_at).to eq(Time.utc(2026, 9, 2, 7, 29, 2))
    legacy = source.normalize_legacy('case_enquiry_id' => '101006742914', 'case_status' => 'Closed',
                                     'open_dt' => '2026-08-31T23:14:05.763',
                                     'closed_dt' => '2026-09-09T15:51:43.623')
    expect(legacy.updated_at).to eq(Time.iso8601('2026-09-09T15:51:43.623Z'))
  end

  it 'rejects missing, equal and older reopen attempts but accepts a strictly newer source reopening' do
    Muni::Store.upsert(ticket(status: 'Closed', updated_at: now - 30, closed_at: now - 30,
                              description: 'Original report'))
    [nil, now - 30, now - 31].each do |stamp|
      Muni::Store.upsert(ticket(updated_at: stamp, closed_at: nil))
      expect(map[:represented_count]).to eq(0)
    end
    Muni::Store.upsert(ticket(updated_at: now, closed_at: nil, description: nil))
    expect(map[:represented_count]).to eq(1)
    expect(Muni::Store.find(Muni::Records::ServiceRequest, '1', hall: 'cambridge').description).to eq('Original report')
    Muni::Store.upsert(ticket(hall: 'boston', status: 'Closed', updated_at: now + 1))
    expect(map[:represented_count]).to eq(1)
  end

  it 'uses newer Boston snapshot versions to allow real reopening without inventing ticket timestamps' do
    Muni::Store.upsert(ticket(hall: 'boston', status: 'Closed', source_revision_at: now - 60))
    Muni::Store.upsert(ticket(hall: 'boston', updated_at: now - 1000, source_revision_at: now))
    expect(Muni::Store.find(Muni::Records::ServiceRequest, '1', hall: 'boston').status).to eq('Open')
    Muni::Store.upsert(ticket(hall: 'boston', status: 'Closed', source_revision_at: now - 120))
    expect(Muni::Store.find(Muni::Records::ServiceRequest, '1', hall: 'boston').status).to eq('Open')
  end

  it 'does not mistake a recent collection time for an authoritative version of an old open Boston request' do
    Muni::Store.upsert(ticket(hall: 'boston', updated_at: now - 6_000_000, collected_at: now))
    Muni::Store.upsert(ticket(hall: 'boston', status: 'Closed', updated_at: now - 1000,
                              closed_at: now - 1000, source_revision_at: now - 60))
    expect(Muni::Store.find(Muni::Records::ServiceRequest, '1', hall: 'boston').status).to eq('Closed')
    Muni::Store.upsert(ticket(hall: 'boston', source_revision_at: now - 60, updated_at: now))
    expect(Muni::Store.find(Muni::Records::ServiceRequest, '1', hall: 'boston').status).to eq('Closed')
  end

  it 'hides a source-confirmed closure with no version without guessing its order against a reopening' do
    Muni::Store.upsert(ticket)
    record = ticket(status: 'Archived', updated_at: nil, closed_at: nil,
                    lifecycle_evidence: { raw: { ticket_status: 'Archived' } })
    Muni::Store.persist_lifecycle_batch([record], key: 'unversioned', expected: nil, checkpoint: {})
    expect(Muni::Store.find(Muni::Records::ServiceRequest, '1', hall: 'cambridge').status).to eq('Open')
    expect(map[:represented_count]).to eq(0)
    Muni::Store.upsert(ticket(updated_at: now))
    expect(map[:represented_count]).to eq(0)
    allow(Time).to receive(:now).and_return(now + 120)
    Muni::Store.upsert(ticket(updated_at: now + 60))
    expect(map[:represented_count]).to eq(1)
  end

  it 'commits old-ticket closure and checkpoint together and rolls back failed projection maintenance' do
    Muni::Store.upsert(ticket(opened_at: now - (80 * 86_400)))
    closed = ticket(status: 'Archived', opened_at: now - (80 * 86_400), updated_at: now)
    allow(Muni::ServiceRequestMap).to receive(:persist).and_raise('interrupted')
    expect do
      Muni::Store.persist_lifecycle_batch([closed], key: 'test', expected: nil, checkpoint: { after: '1' })
    end.to raise_error('interrupted')
    expect(Muni::Store.meta('test')).to be_nil
    expect(Muni::Store.find(Muni::Records::ServiceRequest, '1', hall: 'cambridge').status).to eq('Open')
    allow(Muni::ServiceRequestMap).to receive(:persist).and_call_original
    Muni::Store.persist_lifecycle_batch([closed], key: 'test', expected: nil, checkpoint: { after: '1' })
    expect(JSON.parse(Muni::Store.meta('test'))).to eq('after' => '1')
    expect(map[:represented_count]).to eq(0)
    expect(Muni::Store.db[:service_requests].count).to eq(1)
  end

  it 'maintains the projection from the persisted row when a lifecycle feed omits location metadata' do
    Muni::Store.upsert(ticket)
    Muni::ServiceRequestMap.rebuild!
    update = Muni::Records::ServiceRequest.new(hall: 'cambridge', external_id: '1', status: 'Open',
                                               updated_at: now, closed_at: nil)
    Muni::Store.persist_lifecycle_batch([update], key: 'partial', expected: nil, checkpoint: {})
    query = Muni::Data::Query.new('hall' => 'cambridge', 'bbox' => '-71.2,42.3,-71.0,42.5').service_request_query
    expect(query.map[:represented_count]).to eq(1)
    expect(Muni::Store.find(Muni::Records::ServiceRequest, '1', hall: 'cambridge').location).to eq([-71.1, 42.37])
  end

  it 'keeps dry runs read only and resumes after failed source pages without advancing past them' do
    %w[1 2 3].each { |id| Muni::Store.upsert(ticket(id, opened_at: now - 6_000_000)) }
    source = Cambridge::ServiceRequests.new
    allow(source).to receive(:respond_to?).with(:lifecycle_updates).and_return(false)
    allow(source).to receive(:lifecycle_lookup) do |rows|
      rows.map { |row| ticket(row[:external_id], status: 'Archived', updated_at: now, opened_at: row[:opened_at]) }
    end
    dry = described_class.new(source, page_size: 1, max_batches: 1).run
    expect(dry[:batches].find { |batch| batch[:lane].end_with?(':active') }[:changes].length).to eq(1)
    expect(Muni::Store.meta('lifecycle:v1:cambridge:active')).to be_nil
    runner = described_class.new(source, apply: true, page_size: 1, max_batches: 1)
    runner.run
    saved = Muni::Store.meta('lifecycle:v1:cambridge:active')
    allow(source).to receive(:lifecycle_lookup).and_raise('page failed')
    expect { runner.run }.to raise_error('page failed')
    expect(Muni::Store.meta('lifecycle:v1:cambridge:active')).to eq(saved)
    expect(Muni::Store.find(Muni::Records::ServiceRequest, '2', hall: 'cambridge').status).to eq('Open')
  end

  it 'does not equate an absent source row with closure' do
    Muni::Store.upsert(ticket)
    source = Cambridge::ServiceRequests.new
    allow(source).to receive(:respond_to?).with(:lifecycle_updates).and_return(false)
    allow(source).to receive(:lifecycle_lookup).and_return([])
    result = described_class.new(source, apply: true, max_batches: 1).run
    expect(result[:batches].first[:missing]).to eq(['1'])
    expect(Muni::Store.find(Muni::Records::ServiceRequest, '1', hall: 'cambridge').status).to eq('Open')
    expect(map[:represented_count]).to eq(0)
    Muni::Store.upsert(ticket(updated_at: now))
    expect(map[:represented_count]).to eq(1)
  end

  it 'checks recent closed requests for reopening without waiting behind the full historical sweep' do
    Muni::Store.upsert(ticket('1', status: 'Closed', opened_at: now - 6_000_000, closed_at: now - 100))
    Muni::Store.upsert(ticket('99', status: 'Closed', opened_at: now - 1000, closed_at: now - 100))
    source = Cambridge::ServiceRequests.new
    allow(source).to receive(:respond_to?).with(:lifecycle_updates).and_return(false)
    allow(source).to receive(:lifecycle_lookup) do |rows|
      rows.map { |row| ticket(row[:external_id], opened_at: row[:opened_at], updated_at: now, closed_at: nil) }
    end
    result = described_class.new(source, apply: true, max_batches: 1, page_size: 1).run
    lane = result[:batches].find { |batch| batch[:lane].end_with?(':recent_closed') }
    expect(lane).to include(inspected: 1, found: 1, persisted: 1)
    expect(Muni::Store.find(Muni::Records::ServiceRequest, '99', hall: 'cambridge').status).to eq('Open')
    expect(map[:represented_count]).to eq(1)
  end

  it 'parses Cambridge floating source dates in Eastern time independently of host TZ' do
    source = Cambridge::ServiceRequests.new
    expect(source.send(:local_source_time, '2026-08-31T19:13:46.000')).to eq(Time.utc(2026, 8, 31, 23, 13, 46))
    expect(source.send(:local_source_time, '2026-01-31T19:13:46.000')).to eq(Time.utc(2026, 2, 1, 0, 13, 46))
    expect(source.send(:local_source_time, 'bad')).to be_nil
    report = Time.iso8601('2026-09-18T16:00:00-04:00')
    expect(Muni::ServiceRequestPolicy.map_eligible?(ticket(opened_at: report), now: now)).to be(true)
    expect(Muni::ServiceRequestPolicy.map_eligible?(ticket(opened_at: report - 0.000001), now: now)).to be(false)
    winter_now = Time.iso8601('2026-11-15T12:00:00-05:00')
    boundary = Time.iso8601('2026-10-16T13:00:00-04:00')
    expect(Muni::ServiceRequestPolicy.map_eligible?(ticket(opened_at: boundary), now: winter_now)).to be(true)
    expect(Muni::ServiceRequestPolicy.map_eligible?(ticket(opened_at: boundary - 1), now: winter_now)).to be(false)
  end

  it 'pages old-ticket modifications by update timestamp and ID with overlap after completion' do
    source = Cambridge::ServiceRequests.new
    client = double('Socrata')
    allow(source).to receive(:socrata).and_return(client)
    stamp = '2026-10-18T12:00:00.000'
    raw = { 'ticket_id' => '2', 'ticket_status' => 'Archived', 'ticket_created_date_time' => '2026-01-01T12:00:00.000',
            'ticket_last_updated_date_time' => stamp }
    expect(client).to receive(:query).with(hash_including(where: include("ticket_id > '1'"),
                                                          order: 'ticket_last_updated_date_time ASC, ticket_id ASC'))
                                     .and_return([raw])
    state = { 'lower' => '2026-10-17T00:00:00', 'upper' => stamp, 'after' => [stamp, '1'] }
    records, next_state = source.lifecycle_updates(state, limit: 1)
    expect(records.first.status).to eq('Archived')
    expect(records.first.closed_at).to be_nil
    expect(records.first.opened_at).to eq(Time.utc(2026, 1, 1, 17))
    expect(next_state['after']).to eq([stamp, '2'])
    expect(client).to receive(:query).and_return([])
    _, completed = source.lifecycle_updates(next_state, limit: 1)
    expect(completed).to eq('lower' => '2026-10-16T12:00:00', 'after' => nil)
  end

  it 'rejects repeated or unordered source pages instead of skipping unseen updates' do
    source = Cambridge::ServiceRequests.new
    stamp = '2026-10-18T12:00:00.000'
    client = double('Socrata')
    allow(source).to receive(:socrata).and_return(client)
    allow(client).to receive(:query).and_return([{ 'ticket_id' => '1', 'ticket_last_updated_date_time' => stamp }])
    state = { 'lower' => '2026-10-17T00:00:00', 'upper' => stamp, 'after' => [stamp, '1'] }
    expect { source.lifecycle_updates(state, limit: 1) }.to raise_error(/unordered/)
  end

  it 'corroborates reopening conflicts directly from update pages instead of waiting for a full ID sweep' do
    source = Cambridge::ServiceRequests.new
    stamp = '2026-10-18T12:00:00.000'
    client = double('Socrata')
    allow(source).to receive(:socrata).and_return(client)
    allow(client).to receive(:query).and_return([{ 'ticket_id' => '1', 'ticket_status' => 'Acknowledged',
                                                 'ticket_last_updated_date_time' => stamp,
                                                 'ticket_closed_date_time' => '2026-10-17T12:00:00.000' }])
    expect(source).to receive(:lifecycle_lookup).with([{ external_id: '1' }])
                                                .and_return([ticket(updated_at: now, closed_at: nil)])
    records, = source.lifecycle_updates({ 'lower' => '2026-10-17T00:00:00', 'upper' => stamp }, limit: 2)
    expect(records.first.closed_at).to be_nil
    expect(records.first.status).to eq('Open')
  end

  it 'refuses a stale reconciliation checkpoint from a concurrent runner' do
    Muni::Store.set_meta('test', 'newer')
    expect do
      Muni::Store.persist_lifecycle_batch([ticket], key: 'test', expected: nil, checkpoint: {})
    end.to raise_error(/changed concurrently/)
    expect(Muni::Store.db[:service_requests].count).to eq(0)
  end

  it 'bounds exact-ID requests to the observed Open311 cap and prefers a newer live closure' do
    source = Cambridge::ServiceRequests.new
    soda = double('Socrata')
    http = instance_double(Muni::Helpers::Http)
    allow(source).to receive_messages(socrata: soda, http: http)
    allow(soda).to receive(:query).and_return([{ 'ticket_id' => '1', 'ticket_status' => 'Open',
                                               'ticket_last_updated_date_time' => '2026-10-17T12:00:00.000' }])
    expect(http).to receive(:get).with('requests.json', { 'service_request_id' => (1..20).to_a.join(',') })
                                 .and_return([{ 'service_request_id' => 1, 'status' => 'closed',
                                               'updated_datetime' => '2026-10-18T12:00:00-04:00' }])
    expect(http).to receive(:get).with('requests.json', { 'service_request_id' => '21' }).and_return([])
    records = source.lifecycle_lookup((1..21).map { |id| { external_id: id.to_s } })
    expect(records.map(&:external_id)).to eq(['1'])
    expect(records.first.status).to eq('Closed')
    expect(records.first.lifecycle_evidence[:url]).to include('/requests/1.json')
  end

  it 'corroborates a reopening when both feeds are active but the export retains an old closure date' do
    source = Cambridge::ServiceRequests.new
    soda = double('Socrata')
    http = instance_double(Muni::Helpers::Http)
    allow(source).to receive_messages(socrata: soda, http: http)
    allow(soda).to receive(:query).and_return([{ 'ticket_id' => '1', 'ticket_status' => 'Acknowledged',
                                               'ticket_closed_date_time' => '2026-10-17T12:00:00.000',
                                               'ticket_last_updated_date_time' => '2026-10-18T12:00:00.000' }])
    allow(http).to receive(:get).and_return([{ 'service_request_id' => 1, 'status' => 'open',
                                             'updated_datetime' => '2026-10-18T12:00:00-04:00' }])
    record = source.lifecycle_lookup([{ external_id: '1' }]).first
    expect(record.status).to eq('Open')
    expect(record.closed_at).to be_nil
    expect(record.lifecycle_evidence).to include(confirmed_reopened: true)
  end

  it 'does not let an active export mask an equally dated or undated live closure' do
    source = Cambridge::ServiceRequests.new
    soda = double('Socrata')
    http = instance_double(Muni::Helpers::Http)
    allow(source).to receive_messages(socrata: soda, http: http)
    allow(soda).to receive(:query).and_return(%w[1 2].map do |id|
      { 'ticket_id' => id, 'ticket_status' => 'Open', 'ticket_last_updated_date_time' => '2026-10-18T12:00:00.000' }
    end)
    allow(http).to receive(:get).and_return([
                                              { 'service_request_id' => 1, 'status' => 'closed',
'updated_datetime' => '2026-10-18T12:00:00-04:00' },
                                              { 'service_request_id' => 2, 'status' => 'closed' }
                                            ])
    %w[1 2].each { |id| Muni::Store.upsert(ticket(id, updated_at: now - 86_400)) }
    records = source.lifecycle_lookup(%w[1 2].map { |id| { external_id: id } })
    Muni::Store.persist_lifecycle_batch(records, key: 'conflict', expected: nil, checkpoint: {})
    expect(Muni::Store.find(Muni::Records::ServiceRequest, '1', hall: 'cambridge').status).to eq('Closed')
    expect(Muni::Store.find(Muni::Records::ServiceRequest, '2',
                            hall: 'cambridge').lifecycle_source_state).to eq('uncertain')
    expect(map[:represented_count]).to eq(0)
    Muni::Store.upsert(ticket('2', updated_at: now - 1))
    expect(map[:represented_count]).to eq(0)
    allow(Time).to receive(:now).and_return(now + 120)
    Muni::Store.upsert(ticket('2', updated_at: now + 60))
    expect(map[:represented_count]).to eq(1)
  end

  it 'honors corroborated reopening despite a historical Socrata closure date and rejects its later replay' do
    old_close = now - 86_400
    Muni::Store.upsert(ticket(status: 'Open', updated_at: now, closed_at: old_close))
    reopened = ticket(updated_at: now, closed_at: nil,
                      lifecycle_evidence: { confirmed_reopened: true, raw: { status: 'open' } })
    Muni::Store.upsert(reopened)
    expect(map[:represented_count]).to eq(1)
    Muni::Store.upsert(ticket(updated_at: now, closed_at: old_close))
    expect(map[:represented_count]).to eq(1)
    expect(Muni::Store.find(Muni::Records::ServiceRequest, '1', hall: 'cambridge').closed_at).to be_nil
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MessageSpies, RSpec/StubbedMock, RSpec/VerifiedDoubles
