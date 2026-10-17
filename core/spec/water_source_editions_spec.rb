require 'spec_helper'

RSpec.describe Muni::Water::SourceEditions do
  let(:slug) { 'water/charles/epa_buoy' }
  let(:now) { Time.utc(2026, 10, 16, 20) }

  def advance(previous: {}, body: 'edition', modified: nil, records: [], source: slug)
    responses = if body
                  [{ url: Muni::Water::Catalog::BUOY, body: body, retrieved_at: now,
                                         headers: { 'last-modified' => modified } }]
                else
                  []
                end
    client = instance_double(Muni::Water::Client, responses: responses)
    adapter = instance_double(Muni::Water::Adapters::Base, client: client, metadata: {},
                              checkpoint: { 'publisher_observations' => previous })
    described_class.advance(source, adapter, records)
  end

  it 'measures publisher edition intervals independently of poll intervals and preserves 304 metadata' do
    first = advance(modified: (now - 1800).httpdate)
    second = advance(previous: first, modified: now.httpdate)
    expect(second).to include('basis' => 'publisher_timestamp', 'median_interval_seconds' => 1800)
    expect(advance(previous: second, body: nil)).to eq(second)
    expect(advance(previous: second, modified: now.httpdate)).to eq(second)
  end

  it 'labels body-change receipts separately when no publisher clock is available' do
    observed = advance(modified: 'malformed')
    expect(observed).to include('basis' => 'first_observed_body_change', 'edition_count' => 1)
    expect(advance(previous: observed)).to eq(observed)
  end

  it 'does not let older historical USGS windows move the publisher clock backward' do
    source = 'water/charles/usgs'
    current = advance(body: nil, source: source, records: [{ published_at: now }])
    old = advance(previous: current, body: nil, source: source, records: [{ published_at: now - 86_400 }])
    expect(old).to eq(current)
  end
end
