# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Muni::Transit do
  describe Muni::Transit::Stations do
    it 'loads the comprehensive station catalog' do
      expect(described_class.all.length).to be >= 200
    end

    it 'finds stations by MBTA station ID' do
      alewife = described_class.find('place-alfcl')
      expect(alewife).not_to be_nil
      expect(alewife.name).to eq('Alewife')
      expect(alewife.routes).to eq(['Red'])
      expect(alewife.hall).to eq('cambridge')

      porter = described_class.find('place-porter')
      expect(porter).not_to be_nil
      expect(porter.routes).to include('Red', 'CR-Fitchburg')
      expect(porter.is_transfer).to be true
      expect(porter.hall).to eq('cambridge')

      south_station = described_class.find('place-sstat')
      expect(south_station).not_to be_nil
      expect(south_station.name).to eq('South Station')
      expect(south_station.hall).to eq('boston')

      central = described_class.find('place-cntrm')
      expect(central).not_to be_nil
      expect(central.name).to eq('Central')
      expect(central.hall).to eq('cambridge')

      copley = described_class.find('place-coecl')
      expect(copley).not_to be_nil
      expect(copley.name).to eq('Copley')
      expect(copley.hall).to eq('boston')
    end

    it 'resolves canonical MBTA GTFS IDs from canvas placeholders' do
      expect(described_class.canonical_id('place-[#00000]')).to eq('place-cntrm')
      expect(described_class.canonical_id('place-[#00006]')).to eq('place-coecl')
      expect(described_class.canonical_id('place-hvd')).to eq('place-hvd')
    end

    it 'scopes stations by municipal hall' do
      cambridge_stations = described_class.for_hall('cambridge')
      expect(cambridge_stations.map(&:id)).to include('place-alfcl', 'place-porter', 'place-hvd', 'place-knn')
      expect(cambridge_stations.all? { |s| s.hall == 'cambridge' }).to be true

      boston_stations = described_class.for_hall('boston')
      expect(boston_stations.map(&:id)).to include('place-sstat', 'place-north', 'place-park', 'place-dtncx')
      expect(boston_stations.all? { |s| s.hall == 'boston' }).to be true
    end

    it 'generates valid GeoJSON FeatureCollection' do
      geojson = described_class.to_geojson(hall: 'cambridge')
      expect(geojson[:type]).to eq('FeatureCollection')
      expect(geojson[:features]).not_to be_empty

      first = geojson[:features].first
      expect(first[:type]).to eq('Feature')
      expect(first[:geometry][:type]).to eq('Point')
      expect(first[:geometry][:coordinates].length).to eq(2)
      expect(first[:properties][:hall]).to eq('cambridge')
    end
  end

  describe Muni::Transit::Performance do
    it 'provides systemwide on-time performance overview' do
      overview = described_class.system_overview
      expect(overview[:overall_otp]).to eq(89.6)
      expect(overview[:slow_zones_removed_systemwide]).to eq(228)
      expect(overview.dig(:top_performing_line, :name)).to eq('Fairmount Line')
      expect(overview.dig(:most_improved_line, :name)).to eq('Red Line')
    end

    it 'aggregates performance metrics by municipality corridor' do
      camb = described_class.summary_for('cambridge')
      expect(camb[:hall]).to eq('cambridge')
      expect(camb[:corridor_count]).to eq(4)
      expect(camb[:lines].map { |l| l[:route_id] }).to match_array(%w[Red CR-Fitchburg Green-D Green-E])
      expect(camb[:average_otp]).to be >= 80.0
      expect(camb[:slow_zones_cleared]).to be > 0

      bos = described_class.summary_for('boston')
      expect(bos[:hall]).to eq('boston')
      expect(bos[:corridor_count]).to be > 10
      expect(bos[:average_otp]).to be >= 85.0
    end
  end
end
