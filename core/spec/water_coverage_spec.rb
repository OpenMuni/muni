require 'spec_helper'

RSpec.describe Muni::Water::Coverage do
  let(:source) { 'water/charles/epa_buoy' }
  let(:rows) { Muni::Water::Storage.evidence }

  before do
    Muni::Store.ensure_tables!
    rows.insert(external_id: 'first', source_slug: source, kind: 'sensor', observed_at: Time.utc(2026, 7, 1),
                observed_date: '2026-06-30', payload: '{}')
    rows.insert(external_id: 'second', source_slug: source, kind: 'sensor', observed_at: Time.utc(2026, 7, 2),
                observed_date: '2026-07-01', payload: '{}')
    rows.insert(external_id: 'lab', source_slug: 'water/charles/wqp', kind: 'laboratory',
                observed_date: '2026-07-03', payload: '{}')
  end

  it 'keeps timestamp and date-only bounds independent and reflects corrections without a cache' do
    query = Muni::Water::Query.new
    sources = query.coverage.to_h { |row| [row[:id], row] }
    expect(sources.fetch('epa_buoy')).to include(records: 2, newest_observation_at: Time.utc(2026, 7, 2),
                                                 oldest_observation_at: Time.utc(2026, 7, 1),
                                                 newest_observation_date: '2026-07-01',
                                                 oldest_observation_date: '2026-06-30')
    expect(sources.fetch('wqp')).to include(records: 1, newest_observation_at: nil,
                                            newest_observation_date: '2026-07-03')
    expect(sources.fetch('usgs')).to include(records: 0, newest_observation_at: nil)
    rows.where(external_id: 'second').update(observed_at: Time.utc(2026, 6, 29), observed_date: '2026-06-28')
    corrected = query.coverage.find { |row| row[:id] == 'epa_buoy' }
    expect(corrected).to include(records: 2, newest_observation_at: Time.utc(2026, 7, 1),
                                 oldest_observation_at: Time.utc(2026, 6, 29),
                                 oldest_observation_date: '2026-06-28')
  end

  it 'reports processed and changed counts from the latest run, including zero changes' do
    Muni::Water::Storage.db[:water_runs].insert(source_slug: source, records: 100, changes: 2)
    Muni::Water::Storage.db[:water_runs].insert(source_slug: source, records: 10, changes: 0)
    coverage = described_class.new.call.find { |row| row[:id] == 'epa_buoy' }
    expect(coverage).to include(last_run_records: 10, last_run_changes: 0)
  end

  it 'exposes a rollout pause separately from the retained observation freshness' do
    allow(Muni::Water).to receive_messages(processing_enabled?: false, presentation_enabled?: false)
    coverage = described_class.new.call.find { |row| row[:id] == 'epa_buoy' }
    expect(coverage).to include(processing_enabled: false, presentation_enabled: false,
                                collection_status: 'paused', records: 2, newest_observation_date: '2026-07-01')
    expect(Muni::Water::Query.new.envelope).to include(processing_enabled: false, presentation_enabled: false)
  end
end
