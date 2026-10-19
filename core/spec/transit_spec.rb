# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Muni::Transit::Client do
  before { described_class.clear_cache! }

  it 'uses canonical parent station IDs and deduplicates route membership' do
    stop = { 'id' => 'place-cntsq', 'attributes' => { 'name' => 'Central', 'location_type' => 1,
                                                    'latitude' => 42.36, 'longitude' => -71.1,
                                                    'municipality' => 'Cambridge' } }
    allow(described_class).to receive(:pages) do |_path, params|
      %w[Red Green-B].include?(params['filter[route]']) ? [stop] : []
    end
    result = described_class.stations
    expect(result.fetch('data')).to eq([{ 'id' => 'place-cntsq', 'name' => 'Central',
                                           'latitude' => 42.36, 'longitude' => -71.1,
                                           'municipality' => 'Cambridge', 'routes' => %w[Red Green-B] }])
    expect(result['fetched_at']).not_to be_nil
  end

  it 'follows MBTA pagination and rejects links to other hosts' do
    calls = 0
    allow(described_class).to receive(:request) do |_uri|
      calls += 1
      if calls == 1
        { 'data' => [{ 'id' => 'one' }], 'links' => { 'next' => '/stops?page[offset]=100' } }
      else
        { 'data' => [{ 'id' => 'two' }], 'links' => { 'next' => nil } }
      end
    end
    expect(described_class.send(:pages, '/stops', {})).to eq([{ 'id' => 'one' }, { 'id' => 'two' }])
    expect(calls).to eq(2)

    allow(described_class).to receive(:request).and_return('data'  => [],
                                                           'links' => { 'next' => 'https://example.com/' })
    expect { described_class.send(:pages, '/stops', {}) }.to raise_error(described_class::Error, /Invalid MBTA/)
  end

  it 'does not cache failures or turn rate limits into empty success' do
    calls = 0
    allow(described_class).to receive(:pages) do
      calls += 1
      raise described_class::Error.new('MBTA data unavailable (HTTP 429)', status: 429)
    end
    2.times do
      expect { described_class.vehicles }.to raise_error(described_class::Error) { |error|
        expect(error.status).to eq(429)
      }
    end
    expect(calls).to eq(2)
  end

  it 'rejects a station ID absent from the canonical station list' do
    expect { described_class.predictions(stop_id: 'place-[#00000]') }
      .to raise_error(described_class::Error) { |error| expect(error.status).to eq(404) }
  end

  it 'reads alert route membership from MBTA informed entities' do
    alert = { 'id'         => 'alert-1',
              'attributes' => { 'header'          => 'Delay',
                                'active_period'   => [{ 'start' => (Time.now.utc - 60).iso8601, 'end' => nil }],
                                'informed_entity' => [{ 'route' => 'Red' }, { 'route' => 'CR-Fitchburg' }] } }
    allow(described_class).to receive(:pages).and_return([alert])
    expect(described_class.alerts.fetch('data').first['routes']).to eq(['Red'])
  end
end
