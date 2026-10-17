require 'spec_helper'

RSpec.describe Muni::Water::CalculationInvalidation do
  let(:storage) { Muni::Water::Storage }
  let(:now) { Time.utc(2026, 10, 16, 20) }
  let(:date) { '2026-10-15' }
  let(:slug) { 'water/charles/epa_buoy' }

  before { Muni::Store.ensure_tables! }

  def readings(value)
    base = Muni::Water::Adapters::Base.new(id: 'epa_buoy', now: now)
    96.times.map do |index|
      time = Muni::Water::Clock.eastern(date) + (index * 900)
      base.record(id: time.iso8601, kind: 'sensor', location_id: 'epa-buoy', parameter: 'temperature', unit: '°C',
                  method: 'sensor', segment: '2026', observed_at: time, value: value, raw: { value: value })
    end
  end

  def ingest(rows)
    client = instance_double(Muni::Water::Client, responses: [], validators: {})
    adapter = instance_double(Muni::Water::Adapters::Base, collect: rows, locations: [], metadata: {},
                               checkpoint: {}, client: client)
    Muni::Water::Ingestor.new('epa_buoy', now: now).run(adapter: adapter)
  end

  def trend
    filters = { 'source' => slug, 'location' => 'epa-buoy', 'parameter' => 'temperature',
                'unit' => '°C', 'from' => date, 'to' => '2026-10-16' }
    Muni::Water::Trends.new(now: now).call(filters)[:series].first[:points].first
  end

  it 'invalidates current calculations while retaining history and serving corrected fallback values' do
    ingest(readings(10))
    versions = storage.db[:water_daily_summary_versions].all
    signals = storage.db[:water_signal_versions].where(kind: 'sustained_sensor_shift').all
    Muni::Water::Calculations.with_lock do
      expect(ingest(readings(20))).to include(error: nil, calculation_status: 'pending')
      expect(storage.db[:water_daily_summaries].count).to eq(0)
      expect(storage.db[:water_signals].where(kind: 'sustained_sensor_shift').count).to eq(0)
      expect(storage.db[:water_daily_summary_versions].all).to eq(versions)
      expect(storage.db[:water_signal_versions].where(kind: 'sustained_sensor_shift').all).to eq(signals)
      expect(trend).to include(value: 20.0, materialized: false)
    end
    Muni::Water::Calculations.new(now: now).drain
    expect(trend).to include(value: 20.0, materialized: true)
    expect(storage.db[:water_signal_versions].where(kind: 'sustained_sensor_shift').count).to eq(signals.length + 1)
  end

  it 'rolls back invalidation together with evidence if a later publication step fails' do
    ingest(readings(10))
    prior = storage.db[:water_daily_summaries].all
    signals = storage.db[:water_signals].where(kind: 'sustained_sensor_shift').all
    storage.db.run('CREATE TRIGGER reject_calculation_queue BEFORE INSERT ON water_calculation_jobs ' \
                   "BEGIN SELECT RAISE(ABORT, 'queue unavailable'); END")
    expect(ingest(readings(20))[:error]).to be_a(Sequel::DatabaseError)
    expect(storage.evidence.select_map(:value).uniq).to eq([10.0])
    expect(storage.db[:water_daily_summaries].all).to eq(prior)
    expect(storage.db[:water_signals].where(kind: 'sustained_sensor_shift').all).to eq(signals)
  ensure
    storage.db.run('DROP TRIGGER IF EXISTS reject_calculation_queue')
  end

  it 'invalidates current calculations during retained-evidence normalization as well' do
    ingest(readings(10))
    versions = storage.db[:water_daily_summary_versions].all
    storage.evidence.update(normalization_version: 'older-normalization')
    storage.db[:water_revisions].update(fingerprint: 'older-normalization')
    Muni::Water::Calculations.with_lock do
      report = Muni::Water::Reconciler.new(now: now).normalize(source: slug)
      expect(report[:changed]).to eq(96)
      expect(storage.db[:water_daily_summaries].count).to eq(0)
      expect(storage.db[:water_signals].where(kind: 'sustained_sensor_shift').count).to eq(0)
      expect(storage.db[:water_daily_summary_versions].all).to eq(versions)
      expect(trend).to include(value: 10.0, materialized: false)
    end
  end

  it 'invalidates only matching direct-sensor windows through day thirty' do
    row = readings(10).first
    selector = Muni::Water::DailySummaries.selector(row)
    group = selector.slice('location_id', 'parameter', 'unit', 'method', 'segment')
    first = Date.new(2026, 8, 1)
    keys = [first, first + 30, first + 31].map { |last| "shift/#{Muni::Water.hash(group)}/#{last}" }
    publisher = Muni::Water::Signals.new(now: now)
    keys.each { |key| publisher.publish(key, 'sustained_sensor_shift', 'detected', source_slug: slug) }
    work = described_class.new([{ selector: selector, date: first.to_s }], now: now)
    Muni::Store.with_writer { storage.db.transaction { work.publish } }
    expect(storage.db[:water_signals].select_map(:signal_key)).to eq([keys.last])
    expect(storage.db[:water_signal_versions].count).to eq(3)
  end
end
