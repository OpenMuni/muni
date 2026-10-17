require 'spec_helper'

RSpec.describe Muni::Water::CalculationFence do
  let(:now) { Time.utc(2026, 10, 16, 20) }
  let(:summaries) { Muni::Water::DailySummaries.new(now: now) }
  let(:selector) { Muni::Water::DailySummaries.selector(reading(10)) }
  let(:dirty) { [{ selector: selector, date: '2026-10-15' }] }
  let(:shifts) { Muni::Water::SensorShifts.new(now: now, publisher: Muni::Water::Signals.new(now: now)) }

  before { Muni::Store.ensure_tables! }

  def storage = Muni::Water::Storage

  def reading(value, id: 'epa_buoy')
    Muni::Water::Adapters::Base.new(id: id, now: now).record(
      id: 'reading', kind: id == 'epa_buoy' ? 'sensor' : 'gauge', location_id: 'epa-buoy',
      parameter: 'temperature', unit: '°C', method: 'sensor', segment: '2026',
      observed_at: now - 86_400, value: value, raw: { value: value }
    )
  end

  def ingest(value, id: 'epa_buoy')
    client = instance_double(Muni::Water::Client, responses: [], validators: {})
    adapter = instance_double(Muni::Water::Adapters::Base, collect: [reading(value, id: id)], locations: [],
                               metadata: {}, checkpoint: {}, client: client)
    Muni::Water::Ingestor.new(id, now: now).run(adapter: adapter)
  end

  def after_read(object, method, &correction)
    pending = true
    allow(object).to receive(method).and_wrap_original do |original, *args|
      result = original.call(*args)
      if pending
        pending = false
        correction.call
      end
      result
    end
  end

  it 'rejects a stale summary after a correction commits, backs off, and rebuilds current evidence' do
    Muni::Water::Calculations.with_lock { ingest(10) }
    allow(Muni::Water::DailySummaries).to receive(:new).and_return(summaries)
    after_read(summaries, :prepare) { expect(ingest(20)[:error]).to be_nil }
    Muni::Water::Calculations.new(now: now).drain(limit: 1)
    expect(storage.db[:water_daily_summaries].count).to eq(0)
    expect(storage.db[:water_daily_summary_versions].count).to eq(0)
    expect(storage.db[:water_calculation_jobs].order(:id).first).to include(status: 'failed', retry_at: now + 30)
    Muni::Water::Calculations.new(now: now + 30).drain
    expect(storage.db[:water_calculation_jobs].select_map(:status)).to eq(%w[complete complete])
    expect(JSON.parse(storage.db[:water_daily_summaries].get(:payload))['median']).to eq(20.0)
  end

  it 'does not reject a calculation because an unrelated source published newer evidence' do
    ingest(10)
    after_read(summaries, :prepare) { expect(ingest(30, id: 'usgs')[:error]).to be_nil }
    Muni::Water::Calculations.with_lock { expect { summaries.refresh(dirty) }.not_to raise_error }
    row = storage.db[:water_daily_summaries].where(source_slug: 'water/charles/epa_buoy').first
    expect(JSON.parse(row[:payload])['median']).to eq(10.0)
    expect(row[:revision_cutoff]).to be < storage.db[:water_revisions].max(:id)
  end

  it 'does not restore an invalidated earlier shift from cached summaries' do
    ingest(10)
    versions = storage.db[:water_signal_versions].where(kind: 'sustained_sensor_shift').all
    after_read(shifts, :cached_days) { expect(ingest(20)[:error]).to be_nil }
    Muni::Water::Calculations.with_lock do
      expect { shifts.calculate(dirty: dirty) }.to raise_error(Muni::Water::Error, /inputs changed/)
    end
    expect(storage.db[:water_signals].where(kind: 'sustained_sensor_shift').count).to eq(0)
    expect(storage.db[:water_signal_versions].where(kind: 'sustained_sensor_shift').all).to eq(versions)
  end

  it 'does not publish a new shift from cached summaries invalidated before its first publication' do
    Muni::Water::Calculations.with_lock do
      ingest(10)
      summaries.refresh(dirty)
      after_read(shifts, :cached_days) { expect(ingest(20)[:error]).to be_nil }
      expect { shifts.calculate(dirty: dirty) }.to raise_error(Muni::Water::Error, /inputs changed/)
    end
    expect(storage.db[:water_signals].where(kind: 'sustained_sensor_shift').count).to eq(0)
    expect(storage.db[:water_signal_versions].where(kind: 'sustained_sensor_shift').count).to eq(0)
  end
end
