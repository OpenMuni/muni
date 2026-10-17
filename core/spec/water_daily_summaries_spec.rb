require 'spec_helper'

RSpec.describe Muni::Water::DailySummaries do
  let(:start) { Time.utc(2026, 10, 15, 4) }
  let(:finish) { start + 86_400 }
  let(:rows) do
    96.times.map do |index|
      { external_id: index.to_s, observed_at: start + (900 * index), value: 10.0,
        normalization_version: Muni::Water::Normalization::VERSION,
        payload: '{"calculation_eligible":true}' }
    end
  end

  def statistics(records = rows, at: finish)
    described_class.statistics(records, start: start, finish: finish, interval: 900, now: at)
  end

  it 'uses the actual local-day duration on both daylight-saving transitions' do
    expected = { Date.new(2026, 3, 8) => 92, Date.new(2026, 11, 1) => 100 }
    expected.each do |date, intervals|
      first, last = Muni::Water::Clock.bounds(date)
      stats = described_class.statistics([], start: first, finish: last, interval: 900, now: last)
      expect(stats[:expected]).to eq(intervals)
      expect(stats[:partial]).to be(false)
    end
  end

  it 'uses only elapsed observations for a partial day' do
    stats = statistics(at: start + 3600)
    expect(stats).to include(expected: 4, received: 4, partial: true, coverage: 1.0, median: 10.0)
  end

  it 'excludes unusable rows and suppresses medians below the coverage threshold' do
    rows.last(20).each { |row| row[:payload] = '{"calculation_eligible":false}' }
    stats = statistics
    expect(stats).to include(received: 76, expected: 96, published: 96, value: nil)
    expect(stats[:coverage]).to be < 0.8
    expect(stats[:eligibility_reason]).to include('Fewer than 80%')
  end

  it 'has deterministic input fingerprints and counts an observation timestamp once' do
    original = statistics
    expect(statistics(rows.reverse)[:input_fingerprint]).to eq(original[:input_fingerprint])
    duplicate = rows.first.merge(external_id: 'duplicate')
    expect(statistics(rows + [duplicate])).to include(received: 96, published: 97, value: 10.0)
    rows.first[:payload] = '{"calculation_eligible":true,"quality_flags":["provisional"]}'
    expect(statistics[:input_fingerprint]).not_to eq(original[:input_fingerprint])
  end

  it 'retains previous calculation versions when corrections change a daily summary' do
    Muni::Store.ensure_tables!
    record = Muni::Water::Adapters::Base.new(id: 'epa_buoy', now: start).record(
      id: 'revisioned', kind: 'sensor', location_id: 'epa-buoy', parameter: 'temperature',
      unit: '°C', observed_at: start, value: 10.0, raw: { temperature: '10' }
    )
    writer = Muni::Water::EvidenceWriter.new(now: finish)
    writer.call([record])
    dirty = described_class.dirty(writer.changes)
    calculator = described_class.new(now: finish)
    calculator.refresh(dirty)
    versions = Muni::Water::Storage.db[:water_daily_summary_versions]
    original = versions.first
    calculator.refresh(dirty)
    expect(versions.count).to eq(1)

    writer.call([record.merge(value: 20.0, raw: { temperature: '20' })])
    calculator.refresh(dirty)
    expect(versions.count).to eq(2)
    expect(versions.where(id: original[:id]).first).to eq(original)
    projection = Muni::Water::Storage.db[:water_daily_summaries].first
    expect([projection, original].map { |row| JSON.parse(row[:payload])['median'] }).to eq([20.0, 10.0])
  end
end
