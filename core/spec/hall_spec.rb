require 'spec_helper'

RSpec.describe Muni::Hall do
  it 'loads Cambridge from the shipped YAML' do
    halls = described_class.all
    expect(halls.map(&:slug)).to match_array(%w[boston cambridge])

    cambridge = described_class.find('cambridge')
    expect(cambridge.name).to eq('Cambridge, MA')
    expect(cambridge.timezone).to eq('America/New_York')
    expect(cambridge.center).to eq([-71.1097, 42.3736])
    expect(cambridge.boundary['type']).to eq('Polygon')
    expect(cambridge.boundary.dig('coordinates', 0).length).to be > 50
    expect(cambridge.source_slugs).to include('cambridge/service_requests', 'cambridge/tree_inventory')
  end

  it 'loads Boston as a read-only Hall without bundled third-party boundary coordinates' do
    boston = described_class.find('boston')

    expect(boston.name).to eq('Boston, MA')
    expect(boston.boundary).to be_nil
    expect(boston.capabilities).to eq(report: false, meetings: false, read: true)
    expect(boston.source_slugs).to include('boston/service_requests', 'boston/city_calendar')
  end
end
