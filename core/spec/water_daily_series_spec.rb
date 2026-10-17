require 'spec_helper'

RSpec.describe Muni::Water::DailySeries do
  let(:now) { Time.utc(2026, 10, 17, 4) }
  let(:source) { 'water/charles/epa_buoy' }
  let(:params) do
    { 'source' => source, 'location' => 'epa-buoy', 'parameter' => 'temperature', 'unit' => '°C' }
  end
  let(:selector) do
    { source_slug: source, kind: 'sensor', location_id: 'epa-buoy', parameter: 'temperature',
      unit: '°C', method: 'sensor', segment: '2026' }
  end

  before { Muni::Store.ensure_tables! }

  def readings(date, count: 96, **attrs)
    start = Muni::Water::Clock.eastern(date)
    count.times do |index|
      row = selector.merge(external_id: "#{date}-#{index}", value: 10, observed_at: start + (index * 900),
                           fetched_at: now, payload: '{}').merge(attrs)
      Muni::Water::Storage.evidence.insert(row)
    end
  end

  def summarize(*dates)
    Muni::Water::DailySummaries.new(now: now).refresh(dates.map { |date| { selector: selector, date: date } })
  end

  it 'uses durable complete-day statistics and recomputes only the selected boundary intervals' do
    %w[2026-10-14 2026-10-15 2026-10-16].each { |date| readings(date) }
    summarize('2026-10-14', '2026-10-15', '2026-10-16')
    series = described_class.new(now: now).call(params, from: Time.utc(2026, 10, 14, 6),
                                                        to:   Time.utc(2026, 10, 16, 12))
    points = series.first[:points]
    expect(points.map { |point| point[:materialized] }).to eq([false, true, false])
    expect(points.map { |point| point[:expected] }).to eq([88, 96, 32])
    expect(points.map { |point| point[:partial] }).to eq([true, false, true])
    expect(points.map { |point| point[:value] }).to eq([10, 10, 10])
    expect(points[1]).to include(policy_version: Muni::Water::DailySummaries::POLICY_VERSION, revision_cutoff: 0)
  end

  it 'uses the same coverage threshold and gaps in trends and series' do
    readings('2026-10-14', count: 60)
    summarize('2026-10-14')
    bounds = params.merge('from' => '2026-10-14', 'to' => '2026-10-15', 'aggregation' => 'day')
    trend = Muni::Water::Trends.new(now: now).call(bounds)[:series].first[:points].first
    series = Muni::Water::Query.new(now: now).series(bounds)[:records].first
    expect(trend.slice(:value, :received, :expected, :coverage, :eligibility_reason))
      .to eq(series.slice(:value, :received, :expected, :coverage, :eligibility_reason))
    expect(trend).to include(value: nil, received: 60, expected: 96, materialized: true)
  end

  it 'reads only disjoint boundary windows around thirty days of durable history without duplicates' do
    dates = (Date.new(2026, 9, 16)..Date.new(2026, 10, 16)).map(&:to_s)
    Muni::Water::Storage.db.transaction { dates.each { |date| readings(date) } }
    summarize(*dates)
    selected_ids = []
    allow(Muni::Water::RecordProjection).to receive(:attach_raw).and_wrap_original do |method, rows|
      selected_ids.concat(rows.map { |row| row[:external_id] })
      method.call(rows)
    end

    points = described_class.new(now: now).call(params, from: Time.utc(2026, 9, 16, 6),
                                                        to:   Time.utc(2026, 10, 16, 12)).first[:points]

    expect(points.map { |point| point[:received] }).to eq([88] + ([96] * 29) + [32])
    expect(points.count { |point| point[:materialized] }).to eq(29)
    expect(selected_ids.length).to eq(120)
    expect(selected_ids.uniq.length).to eq(120)
    expect(selected_ids.all? { |id| id.start_with?('2026-09-16-', '2026-10-16-') }).to be(true)
  end

  it 'does not reuse a full-day statistic for an incomplete current day' do
    readings('2026-10-16')
    summarize('2026-10-16')
    midday = Time.utc(2026, 10, 16, 16)
    points = described_class.new(now: midday).call(params, from: Time.utc(2026, 10, 16, 4), to: now).first[:points]
    expect(points.first).to include(materialized: false, partial: true, expected: 48, received: 48, value: 10)
  end

  it 'uses the requested partial interval consistently in both chart endpoints' do
    readings('2026-10-14')
    bounds = params.merge('from' => '2026-10-14T06:00:00Z', 'to' => '2026-10-14T08:00:00Z', 'aggregation' => 'day')
    trend = Muni::Water::Trends.new(now: now).call(bounds)[:series].first[:points].first
    series = Muni::Water::Query.new(now: now).series(bounds)[:records].first
    expect(trend).to include(value: 10, received: 8, expected: 8, coverage: 1.0, partial: true)
    expect(series).to include(value: 10, received: 8, expected: 8, coverage: 1.0, partial: true)
  end
end
