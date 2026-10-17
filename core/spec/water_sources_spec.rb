require 'spec_helper'

RSpec.describe Muni::Water::Client do
  before { Muni::Store.ensure_tables! }

  it 'uses conditional validators without turning a 304 into a new observation' do
    url = Muni::Water::Catalog::BUOY
    stub_request(:get, url).to_return(status: 200, body: "date,value\n2026-01-01,1\n", headers: { 'ETag' => 'v1' })
    first = described_class.new
    expect(first.get(url)).to include('date,value')
    second = described_class.new({ 'validators' => first.validators })
    stub_request(:get, url).with(headers: { 'If-None-Match' => 'v1' }).to_return(status: 304)
    expect(second.get(url)).to be_nil
    expect(second.responses).to eq([])
  end

  it 'resumes completed HTTP pages without exposing an incomplete snapshot' do
    url = "#{Muni::Water::Catalog::USGS}/continuous/items"
    stub_request(:get, url).to_return(status: 200, body: '{"features":[],"links":[]}')
    first = described_class.new({}, slug: 'water/charles/usgs')
    first.get(url)
    second = described_class.new({}, slug: 'water/charles/usgs')
    expect(second.get(url)).to include('features')
    expect(second.snapshot_time.to_i).to eq(first.snapshot_time.to_i)
    expect(a_request(:get, url)).to have_been_made.once
    expect(Muni::Water::Storage.evidence.count).to eq(0)
    expect(Muni::Water::Storage.db[:water_pending_pages].count).to eq(1)
  end

  it 'rejects malformed sensor schemas without erasing retained data' do
    stub_request(:get, Muni::Water::Catalog::BUOY).to_return(status: 200, body: "wrong,header\n1,2\n")
    result = Muni::Water::Ingestor.new('epa_buoy').run
    expect(result[:error]).to be_a(Muni::Water::Error)
    expect(Muni::Water::Storage.checkpoint('water/charles/epa_buoy')).to eq({})
    expect(Muni::Water::Storage.db[:water_pending_pages].count).to eq(0)
    expect(Muni::Water::Storage.db[:water_responses].count).to eq(1)
  end
end
