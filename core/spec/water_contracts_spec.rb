require 'spec_helper'

RSpec.describe Muni::Water::Adapters do
  def fixture(name)
    File.read(File.expand_path("../../spec/fixtures/water/#{name}", __dir__))
  end

  before { Muni::Store.ensure_tables! }

  it 'retains modern USGS identifiers, provisional status, units and source modification time' do
    source = Muni::Water::Adapters::Usgs.new(id: 'usgs')
    row = source.send(:observation, JSON.parse(fixture('usgs.json'))['features'].first)
    expect(row[:kind]).to eq('gauge')
    expect(row[:unit]).to eq('ft^3/s')
    expect(row[:status]).to eq('Provisional')
    expect(row[:published_at]).to be_a(Time)
    expect(row[:payload][:contextual_only]).to be(true)
  end

  it 'preserves ArcGIS publications without importing its safety classifications' do
    source = Muni::Water::Adapters::CrwaLaboratory.new(id: 'crwa_laboratory')
    raw = JSON.parse(fixture('laboratory.json'))['features'].first['attributes']
    row = source.send(:sample, raw)
    expect(row[:unit]).to eq(raw['Unit_Abbreviation'])
    expect(row[:raw]).to eq(raw)
    expect(row[:payload]).not_to have_key(:safety)
    expect(row[:payload][:publication_overlap]).to include('not pooled')
  end

  it 'parses Cambridge normal notices, retractions and conflicting revision times separately' do
    stub_request(:get, Muni::Water::Catalog::CAMBRIDGE).to_return(body: fixture('cambridge.html'))
    rows = Muni::Water::Adapters::CambridgeCso.new(id: 'cambridge_cso').collect
    expect(rows.map { |row| row[:status] }).to include('published', 'retracted', 'needs_review')
    expect(rows.map { |row| row[:location_id] }.uniq).to eq(['CAM005'])
    expect(rows.map { |row| row[:reach_id] }.uniq).to eq(['3'])
  end

  it 'filters MWRA notices by Charles receiving water and preserves treatment and historical averages' do
    stub_request(:get, Muni::Water::Catalog::MWRA).to_return(body: fixture('mwra.csv'))
    rows = Muni::Water::Adapters::MwraCso.new(id: 'mwra_cso').collect
    expect(rows.length).to eq(2)
    expect(rows.map { |row| row[:payload][:receiving_water] }.uniq).to eq(['Charles River'])
    expect(rows.first[:payload][:historical_average]).not_to be_nil
    expect(rows.first[:raw]['source_row']).to have_key('Map ID')
  end
end
