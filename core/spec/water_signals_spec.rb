require 'spec_helper'

RSpec.describe Muni::Water::SensorShifts do
  let(:now) { Time.utc(2026, 10, 16, 20) }
  let(:detector) { described_class.new(now: now, publisher: publisher) }
  let(:group) { { location_id: 'epa-buoy', parameter: 'temperature', unit: '°C', method: 'sensor', segment: '2026' } }
  let(:days) do
    ((date - 30)..date).each_with_index.to_h do |day, index|
      [day, { median: index < 28 ? (index % 3) - 1 : 10, received: 96, expected: 96, coverage: 1.0 }]
    end
  end
  let(:date) { Date.new(2026, 10, 15) }

  def storage = Muni::Water::Storage
  def publisher = Muni::Water::Signals.new(now: now)

  before { Muni::Store.ensure_tables! }

  def calculate(input = days, selector = group)
    detector.evaluate(input, selector, date, latest: true)
    storage.db[:water_signals].order(Sequel.desc(:generated_at)).first
  end

  it 'detects three sustained daily shifts with the exact robust-SD rule and provenance' do
    signal = calculate
    payload = JSON.parse(signal[:payload])
    expect(signal[:status]).to eq('detected')
    expect(payload['direction']).to eq('higher')
    expect(payload['robust_standard_deviation']).to eq(1.4826)
    expect(payload.dig('coverage', 'qualifying_baseline_days')).to eq(28)
    expect(payload.dig('window', 'timezone')).to eq('America/New_York')
    expect(payload['method_version']).to eq(Muni::Water::Signals::METHOD_VERSION)
  end

  it 'does not classify ordinary variation or mixed directions as sustained' do
    days[date][:median] = -10
    expect(calculate[:status]).to eq('not_detected')
    ((date - 2)..date).each { |day| days[day][:median] = 2 }
    expect(calculate[:status]).to eq('not_detected')
  end

  it 'suppresses inadequate daily coverage, too few baseline days and zero dispersion' do
    days[date][:coverage] = 0.79
    expect(calculate[:status]).to eq('suppressed')
    days[date][:coverage] = 0.8
    ((date - 30)..(date - 23)).each { |day| days[day][:coverage] = 0.79 }
    expect(calculate[:status]).to eq('suppressed')
    days.each_value do |day|
      day[:coverage] = 1
      day[:median] = 10
    end
    expect(calculate[:status]).to eq('suppressed')
  end

  it 'retains earlier calculations when late data or corrections remove a shift' do
    calculate
    days[date][:median] = 0
    expect(calculate[:status]).to eq('not_detected')
    expect(storage.db[:water_signal_versions].select_map(:status)).to contain_exactly('detected', 'not_detected')
    calculate
    expect(storage.db[:water_signal_versions].count).to eq(2)
  end

  it 'keeps method, unit and deployment comparisons separate' do
    calculate
    calculate(days, group.merge(method: 'replacement sensor'))
    calculate(days, group.merge(unit: '°F'))
    calculate(days, group.merge(segment: '2027'))
    expect(storage.db[:water_signals].count).to eq(4)
  end

  it 'retains a new history entry when later corrections restore an earlier classification' do
    first = calculate
    days[date][:median] = 0
    calculate
    days[date][:median] = 10
    restored = calculate
    expect(restored[:status]).to eq('detected')
    expect(restored[:id]).not_to eq(first[:id])
    expect(storage.db[:water_signal_versions].count).to eq(3)
    expect(storage.db[:water_signal_versions].where(status: 'detected').count).to eq(2)
  end

  it 'revises invalidated historical findings and preserves their transition history' do
    old_date = date - 10
    input = days.transform_keys { |day| day - 10 }
    detector.evaluate(input, group, old_date, latest: false)
    storage.db[:water_signals].delete
    input[old_date][:median] = 0
    detector.evaluate(input, group, old_date, latest: false)
    expect(storage.db[:water_signals].first[:status]).to eq('not_detected')
    storage.db[:water_signals].delete
    input[old_date][:median] = 10
    detector.evaluate(input, group, old_date, latest: false)
    expect(storage.db[:water_signal_versions].count).to eq(3)
    expect(storage.db[:water_signal_versions].where(status: 'detected').count).to eq(2)
  end
end
