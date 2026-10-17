require 'spec_helper'

RSpec.describe Muni::Water::Client do
  before { Muni::Store.ensure_tables! }

  it 'accepts the publisher-selected CSV format instead of forcing JSON negotiation' do
    url = "#{Muni::Water::Catalog::WQP}/Station/search?mimeType=csv&organization=CRWA"
    stub_request(:get, url).with(headers: { 'Accept' => '*/*' }).to_return(
      body:    "Location_Identifier,Location_Name\nCRWA-1NBS,North Beacon\n",
      headers: { 'Content-Type' => 'text/csv' }
    )
    expect(described_class.new.get(url)).to include('CRWA-1NBS,North Beacon')
    expect(a_request(:get, url)).to have_been_made.once
  end

  it 'makes one attempt and exposes a typed transient failure with the server retry time' do
    url = Muni::Water::Catalog::BUOY
    stub_request(:get, url).to_return(status: 429, headers: { 'Retry-After' => '120' }, body: 'Try later')
    started = Time.now.utc
    expect { described_class.new.get(url) }.to raise_error(Muni::Helpers::Http::Error) { |error|
      expect(error.retryable?).to be(true)
      expect(error.retry_at).to be >= started + 120
    }
    expect(a_request(:get, url)).to have_been_made.once
  end

  it 'preserves validators and original source metadata on a 304' do
    url = Muni::Water::Catalog::BUOY
    prior = { 'validators' => { url => { 'If-None-Match' => 'version-1' } },
              'metadata'   => { 'deployment_year' => 2026 } }
    stub_request(:get, url).with(headers: { 'If-None-Match' => 'version-1' }).to_return(status: 304)
    source = Muni::Water::Adapters::Buoy.new(id: 'epa_buoy', checkpoint: prior)

    expect(source.collect).to eq([])
    expect(source.metadata).to eq(prior['metadata'])
    expect(source.client.validators).to eq(prior['validators'])
    expect(source.client.last_checked_at).to be_a(Time)
    expect(source.client.responses).to be_empty
  end

  it 'bypasses pending pages for edition verification and discards an abandoned snapshot' do
    url = Muni::Water::Catalog::ARCGIS
    stub_request(:get, url).to_return(body: '{"edition":1}').then.to_return(body: '{"edition":2}')
    client = described_class.new({}, slug: 'water/charles/crwa_laboratory')
    expect(client.get(url)).to include('1')
    expect(client.get(url)).to include('1')
    expect(client.fresh_get(url)).to include('2')
    client.discard_pending!
    expect(client.responses).to be_empty
    expect(Muni::Water::Storage.db[:water_pending_pages].count).to eq(0)
    expect(a_request(:get, url)).to have_been_made.twice
  end

  it 'uses retained exact binary document bytes when conditional verification returns 304' do
    url = 'https://example.test/correction.pdf'
    slug = 'water/charles/cambridge_cso'
    bytes = "%PDF\xFF\x00\x80".b
    Muni::Water::Storage.db[:water_responses].insert(source_slug: slug, url: url, retrieved_at: Time.now.utc,
                                                     headers: '{}', body: Sequel.blob(Zlib.gzip(bytes)))
    stub_request(:get, url).with(headers: { 'If-None-Match' => 'pdf-1' }).to_return(status: 304)
    client = described_class.new({ 'validators' => { url => { 'If-None-Match' => 'pdf-1' } } }, slug: slug)
    expect(client.document_bytes(url)).to eq(bytes)
    expect(a_request(:get, url)).to have_been_made.once
  end

  it 'retains raw response timestamps and bytes through the shared transport' do
    url = 'https://example.test/data'
    stub_request(:get, url).to_return(body: '{"sample":1}', headers: { 'Content-Type' => 'application/json' })
    response = Muni::Helpers::Http.new(base_url: 'https://example.test', retries: 0).get_response('/data')
    expect(response.body).to eq('{"sample":1}')
    expect(response.retrieved_at).to be_a(Time)
    expect(response.url).to eq(url)
    expect(response.headers['content-type']).to eq('application/json')
  end

  it 'follows the Cambridge correction document redirect and retains it through journal replay' do
    url = 'https://www.cambridgema.gov/-/media/Files/correction.pdf'
    target = 'https://www.cambridgema.gov/-/media/files/correction.pdf'
    slug = 'water/charles/cambridge_cso'
    bytes = File.binread(File.expand_path('../../spec/fixtures/water/cambridge-2023-correction.pdf', __dir__))
    stub_request(:get, url).to_return(status: 301, headers: { 'Location' => target })
    stub_request(:get, target).to_return(body:    bytes,
                                         headers: {
                                           'Content-Type' => 'application/pdf', 'ETag' => 'pdf-1'
                                         })
    client = described_class.new({}, slug: slug)
    expect(client.document_bytes(url)).to eq(bytes)
    response = client.responses.first
    expect(response).to include(url: url, final_url: target,
                                redirects: [{ 'status' => 301, 'from' => url, 'to' => target }])
    resumed = described_class.new({}, slug: slug)
    expect(resumed.document_bytes(url)).to eq(bytes)
    expect(resumed.responses.first[:final_url]).to eq(target)
    expect(resumed.responses.first[:redirects]).to eq(response[:redirects])
    expect(a_request(:get, url)).to have_been_made.once
    expect(a_request(:get, target)).to have_been_made.once
  end

  it 'expires legacy staged pages using their receipt timestamp when snapshot time was not recorded' do
    url = 'https://example.test/legacy'
    slug = 'water/charles/usgs'
    Muni::Water::Storage.db[:water_pending_pages].insert(
      source_slug: slug, url: url, retrieved_at: Time.now.utc - 86_401, snapshot_at: nil,
      headers: '{}', body: Sequel.blob(Zlib.gzip('expired'))
    )
    stub_request(:get, url).to_return(body: 'current')
    expect(described_class.new({}, slug: slug).get(url)).to eq('current')
    expect(a_request(:get, url)).to have_been_made.once
  end

  it 'resumes a recent legacy journal from its actual receipt time' do
    url = 'https://example.test/legacy'
    slug = 'water/charles/usgs'
    received = Time.now.utc - 3600
    Muni::Water::Storage.db[:water_pending_pages].insert(
      source_slug: slug, url: url, retrieved_at: received, snapshot_at: nil,
      headers: '{}', body: Sequel.blob(Zlib.gzip('retained'))
    )
    client = described_class.new({}, slug: slug)
    expect(client.get(url)).to eq('retained')
    expect(client.snapshot_time).to be_within(0.000001).of(received)
    expect(client.last_retrieved_at).to be_within(0.000001).of(received)
    expect(a_request(:get, url)).not_to have_been_made
  end

  it 'discards undated journals whose age cannot be verified' do
    url = 'https://example.test/legacy'
    slug = 'water/charles/usgs'
    Muni::Water::Storage.db[:water_pending_pages].insert(
      source_slug: slug, url: url, headers: '{}', body: Sequel.blob(Zlib.gzip('undated'))
    )
    stub_request(:get, url).to_return(body: 'current')
    expect(described_class.new({}, slug: slug).get(url)).to eq('current')
    expect(a_request(:get, url)).to have_been_made.once
  end
end
