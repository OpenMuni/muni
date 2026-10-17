require 'spec_helper'

RSpec.describe Muni::Parking do
  def parking_row(extra = {})
    {
      hall:            'cambridge',
      max_minutes:     120,
      hourly_rate:     2.0,
      operation_hours: '8:00AM-8:00PM',
      rule_status:     'rules_known',
      location:        [-71.11, 42.37],
      geometry:        {
        'type'        => 'Polygon',
        'coordinates' => [[
          [-71.1101, 42.3699],
          [-71.1099, 42.3699],
          [-71.1099, 42.3701],
          [-71.1101, 42.3701],
          [-71.1101, 42.3699]
        ]]
      }
    }.merge(extra)
  end

  it 'parses rate, max-time, payment increment, and operating windows' do
    expect(described_class.parse_rate('$1.25')).to eq(1.25)
    expect(described_class.rate_label(1.25)).to eq('$1.25/hr')
    expect(described_class.parse_max_minutes('2 Hours')).to eq(120)
    expect(described_class.max_time_label(30)).to eq('30 min')
    expect(described_class.parse_minutes_per_payment('7.5')).to eq(7.5)
    expect(described_class.normalize_operation_window('8:00AM-6:00PM (Mon-Fri)')).to eq('8 AM-6 PM (Mon-Fri)')
  end

  it 'classifies active, inactive, and unknown meter rules at a requested time' do
    paid_time = Time.utc(2026, 6, 15, 16, 0, 0) # Monday noon in Cambridge.
    outside_time = Time.utc(2026, 6, 15, 2, 0, 0) # Sunday night in Cambridge.

    expect(described_class.status_key(parking_row, at: paid_time)).to eq(:paid_now)
    expect(described_class.status_label(parking_row, at: outside_time)).to eq('Outside meter hours')
    expect(described_class.status_key(parking_row(rule_status: 'unknown_rules', hourly_rate: nil), at: paid_time))
      .to eq(:unknown_rules)
  end

  it 'estimates cost only for billable minutes and caps by max stay' do
    arrive_at = Time.utc(2026, 6, 15, 16, 0, 0)

    estimate = described_class.estimate(parking_row, duration_minutes: 180, at: arrive_at)

    expect(estimate).to include(
      requested_minutes:         180,
      priced_duration_minutes:   120,
      billable_minutes:          120,
      estimated_cost:            4.0,
      exceeds_max_time:          true,
      max_allowed_minutes:       120,
      max_allowed_minutes_label: '2 hours'
    )
  end

  it 'uses preserved geometry for containment and centroid distance for nearby matching' do
    expect(described_class.geometry_contains?(parking_row, -71.11, 42.37)).to be(true)
    expect(described_class.geometry_contains?(parking_row, -71.12, 42.37)).to be(false)
    expect(described_class.distance_meters(parking_row, -71.11, 42.37)).to be_within(0.1).of(0)
  end
end
