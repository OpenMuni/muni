require 'spec_helper'

RSpec.describe Muni::Water do
  let(:now) { Time.utc(2026, 10, 16, 20) }
  let(:storage) { Muni::Water::Storage }

  before { Muni::Store.ensure_tables! }

  def fixture(name)
    File.read(File.expand_path("../../spec/fixtures/water/#{name}", __dir__))
  end

  def adapter(id, klass, response)
    client = instance_double(Muni::Water::Client, get: response, responses: [], validators: {})
    klass.new(id: id, now: now, client: client)
  end

  def ingest(rows, id: 'epa_buoy', at: now, checkpoint: {})
    client = instance_double(Muni::Water::Client, responses: [], validators: {})
    source = instance_double(Muni::Water::Adapters::Base, collect: rows, locations: [], metadata: {},
                             checkpoint: checkpoint, client: client)
    Muni::Water::Ingestor.new(id, now: at).run(adapter: source)
  end

  def reading(time = now, value: 10, **attrs)
    Muni::Water::Adapters::Base.new(id: 'epa_buoy', now: now).record(
      id: time.iso8601, kind: 'sensor', location_id: 'epa-buoy', parameter: 'temperature', unit: '°C',
      method: 'sensor', segment: '2026', observed_at: time, value: value, raw: { value: value }, **attrs
    )
  end

  it 'migrates additively and keeps permanent evidence out of municipal retention and orphan cleanup' do
    result = ingest([reading])
    Muni::Store.ensure_tables!
    expect(result[:error]).to be_nil
    expect(storage.evidence.count).to eq(1)
    expect(Muni::Store.orphan_tables.map { |table| table[:table] }).not_to include(*storage::TABLES.map(&:to_s))
    expect(storage.db[:water_associations].select_map(:hall)).to contain_exactly('cambridge', 'boston')
  end

  it 'retains versions only for semantic changes and never retracts absent rolling records' do
    ingest([reading])
    ingest([reading.merge(fetched_at: now + 900)], at: now + 900)
    ingest([reading(value: 11)], at: now + 1800)
    ingest([], at: now + 2700)
    expect(storage.db[:water_revisions].count).to eq(2)
    expect(storage.evidence.first[:value]).to eq(11)
    expect(storage.db[:water_runs].count).to eq(4)
    expect(storage.db[:water_signals].where(kind: 'published_record_changed').count).to eq(1)
  end

  it 'rolls back malformed imports without promoting a checkpoint or incomplete evidence' do
    ingest([reading])
    result = ingest([reading(now + 900), reading(now + 1800).merge(location_id: nil)],
                    checkpoint: { 'cursor' => 'bad' })
    expect(result[:error]).to be_a(Muni::Water::Error)
    expect(storage.evidence.count).to eq(1)
    expect(storage.checkpoint('water/charles/epa_buoy')).not_to have_key('cursor')
    expect(storage.db[:water_runs].order(:id).last[:status]).to eq('failed')
  end

  it 'retains idempotence and corrections across persistence batches' do
    rows = 501.times.map { |index| reading(now - (index * 900)) }
    expect(ingest(rows)[:rows_upserted]).to eq(501)
    expect(ingest(rows.map { |row| row.merge(fetched_at: now + 900) })[:rows_upserted]).to eq(0)
    rows.last[:value] = 12
    rows.last[:raw] = { value: 12 }
    expect(ingest(rows)[:rows_upserted]).to eq(1)
    expect(storage.evidence.count).to eq(501)
    expect(storage.db[:water_revisions].count).to eq(502)
    expect(storage.db[:water_revisions].where(evidence_id: rows.last[:external_id]).order(:version)
                  .select_map(:version)).to eq([1, 2])
  end

  it 'rolls back every batch when a database failure occurs in a later batch' do
    storage.db.run('CREATE TRIGGER reject_water_test BEFORE INSERT ON water_evidence ' \
                   "WHEN NEW.value = 99999 BEGIN SELECT RAISE(ABORT, 'batch failure'); END")
    rows = 501.times.map { |index| reading(now - (index * 900), value: index == 500 ? 99_999 : 10) }
    result = ingest(rows, checkpoint: { 'cursor' => 'must not publish' })
    expect(result[:error]).to be_a(Sequel::DatabaseError)
    expect(storage.evidence.count).to eq(0)
    expect(storage.db[:water_revisions].count).to eq(0)
    expect(storage.checkpoint('water/charles/epa_buoy')).not_to have_key('cursor')
  ensure
    storage.db.run('DROP TRIGGER IF EXISTS reject_water_test')
  end

  it 'distinguishes stale HTTP success from collection failure and upstream missing intervals' do
    ingest([reading(now - 7200)], at: now - 7200)
    ingest([reading(now - 7200)], at: now)
    source = Muni::Water::Query.new(now: now + 1).coverage.find { |row| row[:id] == 'epa_buoy' }
    expect(source[:status]).to eq('stale')
    expect(source[:collection_status]).to eq('checking')
    ingest([reading.merge(location_id: nil)], at: now + 900)
    source = Muni::Water::Query.new(now: now + 900).coverage.find { |row| row[:id] == 'epa_buoy' }
    expect(source[:collection_status]).to eq('collection_interrupted')
    expect(source[:collection_explanation]).to include('upstream availability unknown')
  end

  it 'preserves filled gaps and supersedes their current classification' do
    start = now - 18_000
    rows = (0..20).reject { |index| index == 4 }.map { |index| reading(start + (index * 900)) }
    ingest(rows, at: start, checkpoint: { 'monitoring_started_at' => start.iso8601 })
    ingest(rows, at: now)
    expect(storage.db[:water_signals].where(kind: 'missing_observations', status: 'active').count).to be_positive
    ingest([reading(start + 3600)], at: now + 1)
    expect(storage.db[:water_signals].where(kind: 'missing_observations', status: 'filled').count).to be_positive
    expect(storage.db[:water_signal_versions].where(kind:   'missing_observations',
                                                    status: 'active').count).to be_positive
  end

  it 'separates direct buoy channels from source estimates with explicit EDT timestamps' do
    source = adapter('epa_buoy', Muni::Water::Adapters::Buoy, fixture('buoy.csv'))
    records = source.collect
    expect(records.map { |row| row[:kind] }.uniq).to contain_exactly('sensor', 'derived_sensor')
    expect(records.first[:original_timezone]).to eq('EDT')
    expect(records.first[:observed_at].utc_offset).to eq(0)
    expect(records.first[:status]).to eq('provisional')
    expect(records.first[:raw].keys.length).to eq(3)
  end

  it 'does not activate retained reason text when CRWA overrides are false' do
    body = JSON.parse(fixture('boathouses.json'))
    body['boathouses'].first.merge!('overridden' => false, 'reason' => 'sewage')
    source = adapter('crwa_boathouses', Muni::Water::Adapters::CrwaBoathouses, JSON.generate(body))
    record = source.collect.first
    expect(record[:status]).to eq('inactive')
    expect(record[:payload][:active]).to be(false)
    expect(record[:payload][:reason]).to eq('sewage')
    expect(record[:observed_at]).to be_nil
  end

  it 'retains sample units, censored values and replicates without pooling publications' do
    source = adapter('wqp', Muni::Water::Adapters::Wqp, fixture('samples.csv'))
    row = CSV.parse(fixture('samples.csv'), headers: true).first.to_h
    row.merge!('Activity_TypeCode' => 'Quality Control Sample-Field Replicate', 'Result_Measure' => '<1',
               'Result_MeasureQualifierCode' => '<')
    sample = source.send(:sample, row)
    expect(sample[:unit]).to eq('MPN/100mL')
    expect(sample[:value]).to be_nil
    expect(sample[:payload][:routine_sample]).to be(false)
    expect(sample[:payload][:original_value]).to eq('<1')
    expect(sample[:raw]).to eq(row)
  end

  it 'flags ambiguous local times and counts both DST day lengths correctly' do
    spring = Muni::Water::Clock.bounds(Date.new(2026, 3, 8))
    fall = Muni::Water::Clock.bounds(Date.new(2026, 11, 1))
    expect((spring.last - spring.first) / 900).to eq(92)
    expect((fall.last - fall.first) / 900).to eq(100)
    expect { Muni::Water::Clock.eastern('2026-11-01', '01:30') }.to raise_error(Muni::Water::Error)
    expect(Muni::Water::Clock.eastern('2026-11-01', '01:30', zone: 'EST')).to eq(Time.utc(2026, 11, 1, 6, 30))
  end

  it 'imports official advisories separately and never hides them behind predictions or expiration' do
    importer = Muni::Water::Ingestor.new('official_advisories', now: now)
    importer.import_advisory(id: 'notice-1', issuer: 'City', source_url: 'https://example.gov/notice', scope: 'charles',
                             reviewer: 'reviewer', title: 'Official notice', expires_at: '2026-10-15T00:00:00Z')
    query = Muni::Water::Query.new(now: now).overview
    expect(query[:advisories].length).to eq(1)
    expect(query[:advisories].first['expiry_state']).to include('no all clear')
    expect(query[:source_coverage].find { |row| row[:id] == 'official_advisories' }[:status]).to eq('incomplete')
  end

  it 'reconstructs the exact retained input versions used by an earlier calculation' do
    ingest([reading])
    cutoff = storage.db[:water_revisions].max(:id)
    publisher = Muni::Water::Signals.new(now: now)
    publisher.publish('test-inputs', 'sustained_sensor_shift', 'detected',
                      source_slug: 'water/charles/epa_buoy',
                      selector:    { location_id: 'epa-buoy', parameter: 'temperature' },
                      evidence:    { revision_cutoff: cutoff },
                      window:      { baseline_start: '2026-10-16', comparison_end: '2026-10-16' })
    signal = storage.db[:water_signals].where(signal_key: 'test-inputs').first
    ingest([reading(value: 11)], at: now + 1)
    original = Muni::Water::Query.new(now: now).signal_evidence(signal[:id])
    expect(original[:records].length).to eq(1)
    expect(original[:records].first[:record]['value']).to eq(10)
    expect(storage.evidence.first[:value]).to eq(11)
  end

  it 'restores permanent evidence, revisions and ingestion history from a SQLite backup' do
    ingest([reading])
    backup = File.join(File.dirname(Muni::Config.db_path), 'water-backup.sqlite3')
    storage.db.run("VACUUM main INTO #{storage.db.literal(backup)}")
    restored = Sequel.sqlite(backup)
    expect(restored[:water_evidence].count).to eq(1)
    expect(restored[:water_revisions].count).to eq(1)
    expect(restored[:water_runs].count).to eq(1)
    restored.disconnect
  end
end
