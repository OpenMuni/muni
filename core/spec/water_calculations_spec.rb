require 'spec_helper'

RSpec.describe Muni::Water::Calculations do
  let(:now) { Time.utc(2026, 10, 16, 20) }
  let(:storage) { Muni::Water::Storage }
  let(:slug) { 'water/charles/epa_buoy' }
  let(:summaries) { Muni::Water::DailySummaries.new(now: now) }

  before { Muni::Store.ensure_tables! }

  def reading(time = now, value: 10, **attrs)
    Muni::Water::Adapters::Base.new(id: 'epa_buoy', now: now).record(
      id: time.iso8601, kind: 'sensor', location_id: 'epa-buoy', parameter: 'temperature', unit: '°C',
      method: 'sensor', segment: '2026', observed_at: time, value: value, raw: { value: value }, **attrs
    )
  end

  def ingest(rows, at: now, checkpoint: {})
    client = instance_double(Muni::Water::Client, responses: [], validators: {})
    adapter = instance_double(Muni::Water::Adapters::Base, collect: rows, locations: [], metadata: {},
                               checkpoint: checkpoint, client: client)
    Muni::Water::Ingestor.new('epa_buoy', now: at).run(adapter: adapter)
  end

  def fail_calculation
    instance = summaries
    allow(Muni::Water::DailySummaries).to receive(:new).and_return(instance)
    allow(instance).to receive(:refresh).and_raise('calculation unavailable')
  end

  it 'keeps published records and the successful checkpoint when calculation fails' do
    fail_calculation
    result = ingest([reading], checkpoint: { 'cursor' => 'published' })
    expect(result).to include(error: nil, rows_upserted: 1, calculation_status: 'failed')
    expect(storage.evidence.count).to eq(1)
    expect(storage.checkpoint(slug)['cursor']).to eq('published')
    expect(storage.db[:water_runs].first[:status]).to eq('complete')
    expect(storage.db[:water_batches].first[:status]).to eq('calculation_failed')
    expect(storage.db[:water_calculation_jobs].first).to include(attempts: 1, retry_at: now + 30)
  end

  it 'backs off failed work durably and recovers without recollecting or revising records' do
    fail_calculation
    ingest([reading])
    expect(described_class.new(now: now + 29).drain).to eq([])
    allow(summaries).to receive(:refresh).and_call_original
    described_class.new(now: now + 30).drain
    expect(storage.db[:water_calculation_jobs].first).to include(status: 'complete', attempts: 2, retry_at: nil)
    expect(storage.db[:water_batches].first[:status]).to eq('complete')
    expect(storage.db[:water_runs].count).to eq(1)
    expect(storage.db[:water_revisions].count).to eq(1)
  end

  it 'lets publication finish while another calculation worker holds its separate lock' do
    described_class.with_lock do
      result = ingest([reading])
      expect(result).to include(error: nil, rows_upserted: 1, calculation_status: 'pending')
      expect(described_class.new(now: now).drain).to eq([])
      expect(storage.evidence.count).to eq(1)
    end
    described_class.new(now: now).drain
    expect(storage.db[:water_calculation_jobs].first[:status]).to eq('complete')
  end

  it 'recovers a job left running by a dead process under the worker lock' do
    described_class.with_lock { ingest([reading]) }
    storage.db[:water_calculation_jobs].update(status: 'running', claim_token: 'dead', attempts: 1)
    described_class.new(now: now + 1).drain
    expect(storage.db[:water_calculation_jobs].first).to include(status: 'complete', attempts: 2, claim_token: nil)
  end

  it 'leaves daily summaries and historical shifts untouched on an unchanged publication' do
    ingest([reading(now - 86_400)])
    days = storage.db[:water_daily_summaries].all
    signals = storage.db[:water_signal_versions].where(kind: 'sustained_sensor_shift').all
    result = ingest([], at: now + 60)
    expect(result[:calculation_status]).to eq('complete')
    expect(storage.db[:water_daily_summaries].all).to eq(days)
    expect(storage.db[:water_signal_versions].where(kind: 'sustained_sensor_shift').all).to eq(signals)
  end

  it 'records exact input revisions independently of unrelated later publications' do
    row = reading(now - 86_400)
    ingest([row])
    old_summary = storage.db[:water_daily_summaries].first
    first_id = storage.db[:water_revisions].max(:id)
    ingest([reading])
    expect(storage.db[:water_daily_summaries].where(date: old_summary[:date]).first).to eq(old_summary)
    expect(JSON.parse(old_summary[:payload])['input_revision_ids']).to eq([first_id])
    ingest([row.merge(value: 11, raw: { value: 11 })], at: now + 1)
    updated = JSON.parse(storage.db[:water_daily_summaries].where(date: old_summary[:date]).get(:payload))
    expect(updated['input_revision_ids']).to eq([storage.db[:water_revisions].max(:id)])
  end

  it 'closes a day once and bounds restart catch-up to one local day per tick' do
    ingest([reading])
    Muni::Store.set_meta('water:last_closed_day', '2026-10-14')
    summaries.close_days
    expect(Muni::Store.meta('water:last_closed_day')).to eq('2026-10-15')
    expect(storage.db[:water_daily_summaries].where(date: '2026-10-15').count).to eq(0)
    summaries.close_days
    expect(Muni::Store.meta('water:last_closed_day')).to eq('2026-10-16')
    days = storage.db[:water_daily_summaries].all
    summaries.close_days
    expect(storage.db[:water_daily_summaries].all).to eq(days)
  end

  it 'never classifies estimates or a partial current day as a completed direct-sensor shift' do
    ingest([reading(now - 86_400, kind: 'derived_sensor')])
    ingest([reading])
    expect(storage.db[:water_signals].where(kind: 'sustained_sensor_shift').count).to eq(0)
  end

  it 'extends the same long gap and fills old gaps without clearing unrelated gaps' do
    start = now - (3 * 86_400)
    rows = [reading(start), reading(start + 1800), reading(now - 86_400)]
    initial = ingest(rows, checkpoint: { 'monitoring_started_at' => start.iso8601 })
    expect(initial[:calculation_status]).to eq('complete')
    active = storage.db[:water_signals].where(kind: 'missing_observations', status: 'active')
    keys = active.select_map(:signal_key)
    expect(ingest([], at: now + 1800)[:calculation_status]).to eq('complete')
    expect(active.select_map(:signal_key)).to match_array(keys)
    ingest([reading(start + 900)], at: now + 1801)
    expect(active.count).to eq(keys.length - 1)
    expect(storage.db[:water_signals].where(kind: 'missing_observations', status: 'filled').count).to eq(1)
    expect(Muni::Store.meta("water:gap_deadline:#{slug}")).to eq((now + 1801 - 7200).iso8601)
  end

  it 'ends old deployment gaps without inventing earlier gaps for its replacement' do
    start = now - 86_400
    ingest([reading(start)], checkpoint: { 'monitoring_started_at' => start.iso8601 })
    ingest([reading(now - 7200, segment: 'replacement')], at: now)
    gaps = storage.db[:water_signals].where(kind: 'missing_observations').all
    expect(gaps.map { |row| row[:status] }).to eq(['resolved'])
    expect(JSON.parse(gaps.first[:payload])['explanation']).to include('replaced this deployment')
  end

  it 'filters normalization-only revisions before looking for publication changes' do
    ingest([reading])
    revision = storage.db[:water_revisions].first
    record = JSON.parse(revision[:record])
    record['payload']['change_kind'] = 'normalization'
    storage.db[:water_revisions].insert(revision.except(:id).merge(version: 3, record: JSON.generate(record)))
    result = ingest([], at: now + 1)
    expect(result[:calculation_status]).to eq('complete')
    Muni::Water::Signals.new(now: now).recalculate(slug: slug, dirty: [])
    expect(storage.db[:water_signals].where(kind: 'published_record_changed').count).to eq(0)
  end
end
