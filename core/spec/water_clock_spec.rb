require 'spec_helper'

RSpec.describe Muni::Water::Clock do
  %w[UTC America/New_York].each do |timezone|
    context "with host timezone #{timezone}" do
      around do |example|
        previous = ENV.fetch('TZ', nil)
        ENV['TZ'] = timezone
        example.run
      ensure
        ENV['TZ'] = previous
      end

      it 'preserves the published explicit offset during a nominal spring gap' do
        early = described_class.eastern('2026-03-08', '02:30:00', zone: 'EDT')
        later = described_class.eastern('2026-03-08', '03:30:00', zone: 'EDT')
        standard = described_class.eastern('2026-03-08', '02:30:00', zone: 'EST')
        expect(early).to eq(Time.utc(2026, 3, 8, 6, 30))
        expect(later - early).to eq(3600)
        expect(standard).to eq(Time.utc(2026, 3, 8, 7, 30))
      end

      it 'retains both explicitly distinguished fall hours' do
        daylight = described_class.eastern('2026-11-01', '01:30', zone: 'EDT')
        standard = described_class.eastern('2026-11-01', '01:30', zone: 'EST')
        expect(daylight).to eq(Time.utc(2026, 11, 1, 5, 30))
        expect(standard).to eq(Time.utc(2026, 11, 1, 6, 30))
      end

      it 'rejects unqualified spring gaps and repeated fall hours before normalization' do
        expect { described_class.eastern('2026-03-08', '02:30') }
          .to raise_error(Muni::Water::Error, /Unresolved daylight-saving/)
        expect { described_class.eastern('2026-11-01', '01:30') }
          .to raise_error(Muni::Water::Error, /Unresolved daylight-saving/)
      end

      it 'keeps local date boundaries and both daylight-saving day lengths' do
        spring = described_class.bounds(Date.new(2026, 3, 8))
        fall = described_class.bounds(Date.new(2026, 11, 1))
        expect(spring.first).to eq(Time.utc(2026, 3, 8, 5))
        expect(fall.first).to eq(Time.utc(2026, 11, 1, 4))
        expect(spring.last - spring.first).to eq(23 * 3600)
        expect(fall.last - fall.first).to eq(25 * 3600)
      end
    end
  end
end
