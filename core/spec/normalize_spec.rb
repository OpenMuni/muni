require 'spec_helper'

RSpec.describe Muni::Helpers::Normalize do
  describe '.parse_time' do
    it 'parses unix epoch seconds' do
      t = described_class.parse_time(1_700_000_000)
      expect(t).to be_a(Time)
      expect(t.utc.to_i).to eq(1_700_000_000)
    end

    it 'parses RFC822 dates' do
      t = described_class.parse_time('Wed, 21 May 2026 12:00:00 EDT')
      expect(t).to be_a(Time)
    end

    it 'parses Cambridge slash dates as month/day/year local time' do
      expect(described_class.parse_time('05/12/2026 20:00')).to eq(Time.local(2026, 5, 12, 20).utc)
      expect(described_class.parse_time('05/31/2026 19:30')).to eq(Time.local(2026, 5, 31, 19, 30).utc)
      expect(described_class.parse_time('03/11/2009 11:00 - 13:00')).to eq(Time.local(2009, 3, 11, 11).utc)
      expect(described_class.parse_time('9/30/2025 4:00:00.000')).to eq(Time.local(2025, 9, 30, 4).utc)
    end
  end
end
