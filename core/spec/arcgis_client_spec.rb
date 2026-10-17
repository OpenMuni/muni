require 'spec_helper'

RSpec.describe Muni::Clients::Arcgis do
  let(:http) { instance_double(Muni::Helpers::Http) }
  let(:client) { described_class.new(base_url: 'https://gis.example.test') }
  let(:query_params) do
    {
      'f'         => 'geojson',
      'where'     => 'FCODE IN (1,21)',
      'outFields' => 'OBJECTID,NAME',
      'outSR'     => 4326
    }
  end

  before do
    allow(Muni::Helpers::Http).to receive(:new).with(base_url: 'https://gis.example.test').and_return(http)
  end

  it 'queries ArcGIS layers as paginated GeoJSON' do
    stub_page(0, [{ 'id' => 1 }, { 'id' => 2 }])
    stub_page(2, [{ 'id' => 3 }])

    rows = client.query_geojson(
      path: '/MapServer/1/query', where: 'FCODE IN (1,21)', out_fields: %w[OBJECTID NAME],
      limit: 4, page_size: 2
    )

    expect(rows.map { |row| row['id'] }).to eq([1, 2, 3])
  end

  it 'caps the final page at the requested limit' do
    allow(http).to receive(:get)
      .with('/MapServer/1/query', hash_including('resultOffset' => 0, 'resultRecordCount' => 3))
      .and_return('features' => [{ 'id' => 1 }, { 'id' => 2 }, { 'id' => 3 }])

    rows = client.query_geojson(
      path: '/MapServer/1/query', limit: 3, page_size: 100
    )

    expect(rows.size).to eq(3)
  end

  def stub_page(offset, features)
    allow(http).to receive(:get)
      .with('/MapServer/1/query', query_params.merge('resultOffset' => offset, 'resultRecordCount' => 2))
      .and_return('features' => features)
  end
end
