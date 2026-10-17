require 'spec_helper'

RSpec.describe Muni::Water::Trends do
  let(:now) { Time.utc(2026, 10, 17, 4) }
  let(:query) { described_class.new(now: now) }
  let(:db) { Muni::Water::Storage.db }
  let(:source) { 'water/charles/epa_buoy' }
  let(:params) do
    { 'source' => source, 'location' => 'epa-buoy', 'parameter' => 'temperature', 'unit' => '°C',
      'from' => '2026-10-14', 'to' => '2026-10-17' }
  end

  before { Muni::Store.ensure_tables! }

  def reading(at, value: 10, **attrs)
    row = { external_id: SecureRandom.uuid, source_slug: source, kind: 'sensor', location_id: 'epa-buoy',
            parameter: 'temperature', unit: '°C', method: 'sensor', segment: '2026', value: value,
            observed_at: at, fetched_at: now, payload: '{}' }.merge(attrs)
    db[:water_evidence].insert(row)
  end

  def day(date, count: 96, **attrs)
    start = Muni::Water::Clock.eastern(date)
    count.times { |index| reading(start + (index * 900), **attrs) }
  end

  it 'returns daily medians with explicit gaps and suppresses inadequate interval coverage' do
    day('2026-10-14', value: 10)
    day('2026-10-16', count: 60, value: 90)
    result = query.call(params)
    points = result[:series].first[:points]
    expect(points.map { |row| row[:value] }).to eq([10, nil, nil])
    expect(points.map { |row| row[:received] }).to eq([96, 0, 60])
    expect(result[:statistic]).to eq('median')
  end

  it 'keeps incompatible units, methods and deployment segments out of the same trend line' do
    day('2026-10-14')
    day('2026-10-15', method: 'replacement', segment: 'new')
    day('2026-10-14', unit: '°F', value: 50)
    series = query.call(params)[:series]
    expect(series.length).to eq(2)
    expect(series.map { |row| row[:unit] }.uniq).to eq(['°C'])
    expect(series.map { |row| row[:method] }).to contain_exactly('sensor', 'replacement')
  end

  it 'counts lab publications without averaging censored samples or converting units' do
    reading(now - 86_400, kind: 'laboratory', source_slug: 'water/charles/wqp', value: nil, unit: 'MPN/100mL')
    reading(now - 86_400, kind: 'laboratory', source_slug: 'water/charles/wqp', unit: 'CFU/100mL')
    result = query.call(params.slice('from', 'to').merge('source' => 'water/charles/wqp'))
    expect(result[:statistic]).to eq('count')
    expect(result[:series].length).to eq(1)
    expect(result[:series].first[:points].map { |row| row[:value] }).to eq([nil, nil, 2])
  end

  it 'excludes retracted and ambiguous discharge publications without summing volume' do
    %w[published retracted needs_review].each do |status|
      reading(now - 3600, kind: 'discharge', source_slug: 'water/charles/mwra_cso', status: status, value: 50)
    end
    reading(now - 3600, kind: 'discharge', source_slug: 'water/charles/mwra_cso', payload: '{"countable":false}')
    result = query.call(params.slice('from', 'to').merge('source' => 'water/charles/mwra_cso'))
    expect(result[:record_count]).to eq(1)
    expect(result[:series].first[:points].last[:value]).to eq(1)
    expect(result[:series].first[:unit]).to eq('records')
  end

  it 'charts successful boathouse checks only after monitoring began, without invented state issuance times' do
    slug = 'water/charles/crwa_boathouses'
    db[:water_runs].insert(source_slug: slug, status: 'complete', started_at: now - 3600, ended_at: now)
    db[:water_runs].insert(source_slug: slug, status: 'failed', started_at: now - 1800)
    result = query.call(params.slice('from', 'to').merge('source' => slug))
    expect(result[:series].first[:points].map { |row| row[:value] }).to eq([nil, nil, 1])
    expect(result[:metric]).to eq('Successful checks')
  end

  it 'uses the real DST day length for expected intervals' do
    start = Muni::Water::Clock.eastern('2026-11-01')
    100.times { |index| reading(start + (index * 900)) }
    result = described_class.new(now: start + (100 * 900)).call(params.merge('from' => '2026-11-01',
                                                                             'to'   => '2026-11-02'))
    expect(result[:series].first[:points].first).to include(expected: 100, coverage: 1.0, value: 10)
  end

  it 'rejects unbounded periods and unqualified measurement requests' do
    expect { query.call(params.merge('to' => '2030-01-01')) }.to raise_error(Muni::Water::Error)
    expect { query.call(params.except('location')) }.to raise_error(Muni::Water::Error)
    expect { query.call(params.merge('source' => 'cambridge/unknown')) }.to raise_error(Muni::Water::Error)
  end

  it 'aggregates discharge notices monthly and does not invent zeros beyond the published history' do
    %w[2026-07-02 2026-07-12 2026-09-12].each do |date|
      reading(Muni::Water::Clock.eastern(date), kind: 'discharge', source_slug: 'water/charles/mwra_cso',
              status: 'published')
    end
    result = query.call('source' => 'water/charles/mwra_cso', 'from' => '2026-06-01', 'to' => '2026-10-17',
                        'aggregation' => 'month')
    expect(result[:aggregation]).to eq('month')
    expect(result[:series].first[:points].map { |row| row[:value] }).to eq([nil, 2, 0, 1, nil])
    expect(result[:record_count]).to eq(3)
  end

  it 'excludes withdrawn readings and rejects monthly sensor medians' do
    day('2026-10-14', status: 'retracted')
    expect(query.call(params)[:series].first[:points].map { |point| point[:value] }).to eq([nil, nil, nil])
    expect { query.call(params.merge('aggregation' => 'month')) }.to raise_error(Muni::Water::Error)
  end
end
