require 'spec_helper'

RSpec.describe Muni::LocalTime do
  before { Muni::Hall.load_all! }

  it 'formats Cambridge time in the city timezone during daylight saving time' do
    local = described_class.local_time(Time.utc(2026, 6, 17, 2, 30, 0), city: 'cambridge')

    expect(local.iso8601).to eq('2026-06-16T22:30:00-04:00')
    expect(described_class.timezone_for('cambridge')).to eq('America/New_York')
  end

  it 'formats Cambridge time in standard time outside daylight saving time' do
    local = described_class.local_time(Time.utc(2026, 1, 17, 2, 30, 0), city: 'cambridge')

    expect(local.iso8601).to eq('2026-01-16T21:30:00-05:00')
  end
end
