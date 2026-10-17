require 'spec_helper'

RSpec.describe Muni::Clients::Ckan do
  let(:base_url) { 'https://data.example.gov' }
  let(:client) { described_class.new(base_url: base_url, page_size: 2) }

  it 'resolves named DataStore resources from package metadata' do
    stub_request(:get, "#{base_url}/api/3/action/package_show")
      .with(query: { 'id' => 'city-data' })
      .to_return(
        status:  200,
        headers: { 'Content-Type' => 'application/json' },
        body:    JSON.generate(success: true, result: {
                                 resources: [
                                   { id: 'csv', name: 'Current CSV', datastore_active: false },
                                   { id: 'store', name: 'Current records', datastore_active: true,
                                     last_modified: '2026-08-22T00:00:00Z' }
                                 ]
                               })
      )

    expect(client.resolve_resource('city-data', name: 'current records')['id']).to eq('store')
  end

  it 'paginates DataStore rows without exceeding the requested limit' do
    stub_request(:get, %r{data\.example\.gov/api/3/action/datastore_search}).to_return do |request|
      query = URI.decode_www_form(request.uri.query).to_h
      offset = query.fetch('offset').to_i
      rows = [{ '_id' => offset + 1 }, { '_id' => offset + 2 }]
      rows = rows.first(1) if offset == 2
      {
        status: 200, headers: { 'Content-Type' => 'application/json' },
        body: JSON.generate(success: true, result: { records: rows })
      }
    end

    expect(client.query(resource: 'resource', limit: 3).map { |row| row['_id'] }).to eq([1, 2, 3])
  end

  it 'validates resource IDs before constructing SQL' do
    expect { client.each_sql(resource: 'bad" id').to_a }.to raise_error(ArgumentError, /invalid CKAN resource/)
  end
end
