require 'spec_helper'

RSpec.describe Muni::Water::DailySummaries do
  let(:storage) { Muni::Water::Storage }
  let(:now) { Time.utc(2026, 10, 16, 20) }
  let(:selector) do
    { source_slug: 'water/charles/epa_buoy', kind: 'sensor', location_id: 'epa-buoy', parameter: 'temperature',
      unit: '°C', method: 'sensor', segment: '2026' }
  end
  let(:dirty) { %w[2026-10-14 2026-10-15].map { |date| { selector: selector, date: date } } }
  let(:summaries) { described_class.new(now: now) }

  before do
    Muni::Store.ensure_tables!
    dirty.each do |entry|
      row = selector.merge(external_id: entry[:date], value: 10,
                           observed_at: Muni::Water::Clock.eastern(entry[:date]),
                           normalization_version: Muni::Water::Normalization::VERSION,
                           payload: '{"calculation_eligible":true}')
      storage.evidence.insert(row)
    end
    summaries.refresh(dirty)
  end

  it 'rolls back new immutable versions and all projections when a later projection write fails' do
    versions = storage.db[:water_daily_summary_versions].order(:id).all
    projections = storage.db[:water_daily_summaries].order(:date).all
    storage.evidence.update(value: 20)
    storage.db.run('CREATE TRIGGER reject_summary_update BEFORE UPDATE ON water_daily_summaries ' \
                   "WHEN NEW.date = '2026-10-15' BEGIN SELECT RAISE(ABORT, 'late summary failure'); END")
    expect { summaries.refresh(dirty) }.to raise_error(Sequel::DatabaseError, /late summary failure/)
    expect(storage.db[:water_daily_summary_versions].order(:id).all).to eq(versions)
    expect(storage.db[:water_daily_summaries].order(:date).all).to eq(projections)
    storage.db.run('DROP TRIGGER reject_summary_update')
    summaries.refresh(dirty)
    expect(storage.db[:water_daily_summary_versions].count).to eq(4)
    medians = storage.db[:water_daily_summaries].select_map(:payload).map { |payload| JSON.parse(payload)['median'] }
    expect(medians).to eq([20.0, 20.0])
  ensure
    storage.db.run('DROP TRIGGER IF EXISTS reject_summary_update')
  end

  it 'retains the actual normalization versions of inputs, including explicitly unknown legacy versions' do
    payload = JSON.parse(storage.db[:water_daily_summaries].get(:payload))
    expect(payload['input_normalization_versions']).to eq([Muni::Water::Normalization::VERSION])
    storage.evidence.update(normalization_version: nil)
    summaries.refresh(dirty)
    payload = JSON.parse(storage.db[:water_daily_summaries].get(:payload))
    expect(payload['input_normalization_versions']).to eq(['unknown'])
  end
end
