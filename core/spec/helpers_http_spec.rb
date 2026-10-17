require 'spec_helper'
require 'webmock/rspec'

RSpec.describe Muni::Helpers::Http do
  let(:http) { described_class.new(base_url: 'https://example.test') }

  it 'parses JSON responses' do
    stub_request(:get, 'https://example.test/foo')
      .to_return(status: 200, body: '{"ok":true}', headers: { 'Content-Type' => 'application/json' })
    expect(http.get('/foo')).to eq('ok' => true)
  end

  it 'returns :not_modified on 304 when an etag is supplied' do
    stub_request(:get, 'https://example.test/foo')
      .with(headers: { 'If-None-Match' => 'abc' })
      .to_return(status: 304, body: '')
    expect(http.get('/foo', etag: 'abc')).to eq(:not_modified)
  end

  it 'retries on transient 500s and eventually raises' do
    stub_request(:get, 'https://example.test/boom').to_return(status: 500, body: 'nope')
    expect { http.get('/boom') }.to raise_error(Muni::Helpers::Http::Error, /HTTP 500/)
    expect(WebMock).to have_requested(:get, 'https://example.test/boom').times(4)
  end

  it 'leaves municipal redirects unchanged unless explicitly enabled' do
    stub_request(:get, 'https://example.test/old').to_return(status: 301, headers: { 'Location' => '/new' })
    expect(http.get_response('/old').status).to eq(301)
    expect(a_request(:get, 'https://example.test/new')).not_to have_been_made
  end

  it 'follows relative GET redirects once per hop and preserves provenance' do
    client = described_class.new(base_url: 'https://example.test', retries: 0, follow_redirects: true)
    stub_request(:get, 'https://example.test/old?key=one')
      .to_return(status: 301, headers: { 'Location' => '/new?key=two' })
    stub_request(:get, 'https://example.test/new?key=two').to_return(body: 'document')
    response = client.get_response('/old', { key: 'one' })
    expect(response.url).to eq('https://example.test/new?key=two')
    expect(response.requested_url).to eq('https://example.test/old?key=one')
    expect(response.redirects).to eq([{ 'status' => 301, 'from' => response.requested_url, 'to' => response.url }])
    expect(a_request(:get, response.requested_url)).to have_been_made.once
    expect(a_request(:get, response.url)).to have_been_made.once
  end

  it 'strips credentials from both default and request headers across origins' do
    private_headers = { 'Authorization' => 'Bearer private', 'Cookie' => 'session=private', 'X-App-Token' => 'private' }
    client = described_class.new(base_url: 'https://example.test', retries: 0, follow_redirects: true,
                                 headers: private_headers)
    stub_request(:get, 'https://example.test/old')
      .to_return(status: 302, headers: { 'Location' => 'https://private:secret@other.test/new' })
    stub_request(:get, 'https://other.test/new').with do |request|
      %w[Authorization Cookie X-App-Token X-Api-Key].none? { |header| request.headers.key?(header) }
    end.to_return(body: 'public')
    expect(client.get_response('/old', {}, headers: { 'X-Api-Key' => 'private' }).body).to eq('public')
  end

  it 'bounds redirect chains and does not replay POST requests' do
    client = described_class.new(base_url: 'https://example.test', retries: 0, follow_redirects: true, max_redirects: 1)
    stub_request(:get, 'https://example.test/one').to_return(status: 301, headers: { 'Location' => '/two' })
    stub_request(:get, 'https://example.test/two').to_return(status: 302, headers: { 'Location' => '/three' })
    expect { client.get_response('/one') }.to raise_error(described_class::Error, /redirect limit/)
    expect(a_request(:get, 'https://example.test/three')).not_to have_been_made
    stub_request(:post, 'https://example.test/one').to_return(status: 307, body: 'moved',
                                                              headers: { 'Location' => '/two' })
    expect(client.post('/one', 'body')).to eq('moved')
    expect(a_request(:post, 'https://example.test/two')).not_to have_been_made
  end
end
