require 'spec_helper'

RSpec.describe Muni::Helpers::Geo do
  def polygon(west, south, east, north)
    [[
      [west, south],
      [east, south],
      [east, north],
      [west, north],
      [west, south]
    ]]
  end

  it 'checks point containment inside a polygon boundary' do
    boundary = {
      'type'        => 'Polygon',
      'coordinates' => polygon(-71.2, 42.3, -71.0, 42.5)
    }

    expect(described_class.boundary_contains?(boundary, -71.1, 42.4)).to be(true)
    expect(described_class.boundary_contains?(boundary, -71.3, 42.4)).to be(false)
  end

  it 'checks point containment inside a multipolygon boundary' do
    boundary = {
      'type'        => 'MultiPolygon',
      'coordinates' => [
        polygon(-71.2, 42.3, -71.0, 42.5),
        polygon(-70.9, 42.3, -70.7, 42.5)
      ]
    }

    expect(described_class.boundary_contains?(boundary, -70.8, 42.4)).to be(true)
    expect(described_class.boundary_contains?(boundary, -71.3, 42.4)).to be(false)
  end

  it 'treats missing boundaries as unbounded' do
    expect(described_class.boundary_contains?(nil, -71.3, 42.4)).to be(true)
  end

  it 'rejects malformed and out-of-range coordinates' do
    expect(described_class.point('not-a-longitude', 42.3)).to be_nil
    expect(described_class.point(-71.1, 142.3)).to be_nil
  end
end
