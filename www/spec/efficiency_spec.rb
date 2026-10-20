require 'spec_helper'

RSpec.describe Muni::Www::App do
  def app
    described_class
  end

  before do
    Muni::Store.ensure_tables!
    Muni::EfficiencyIndexes.prepare!
    Muni::Www::Routes::API::PUBLIC_CACHE.clear
    4.times do |i|
      Muni::Store.upsert(Muni::Records::ServiceRequest.new(hall: 'cambridge', external_id: "page-#{i}",
                                                           status: 'Open', description: 'full detail',
                                                           location: [-71.1, 42.37], opened_at: Time.now.utc))
    end
  end

  it 'keeps legacy arrays and full fields, honors limits and exposes the next link' do
    ['/api/category/service_requests/records', '/api/records/cambridge/service_requests'].each do |path|
      get path, hall: 'cambridge', limit: 2
      expect(last_response.status).to eq(200)
      first = JSON.parse(last_response.body)
      expect(first.length).to eq(2)
      expect(first.first['description']).to eq('full detail')
      next_url = last_response.headers.fetch('link')[/<([^>]+)>/, 1]
      get next_url
      expect(last_response.status).to eq(200)
      final = JSON.parse(last_response.body)
      expect(final.length).to eq(2)
      expect((first + final).map { |row| row['external_id'] }.uniq.length).to eq(4)
      expect(last_response.headers['link']).to be_nil
    end
  end

  it 'returns compact pages, validates cursors and fails maps until projection is ready' do
    get '/api/category/service_requests/page', hall: 'cambridge', limit: 1
    page = JSON.parse(last_response.body)
    expect(page['items'].length).to eq(1)
    expect(page['items'].first).not_to have_key('description')
    get '/api/category/service_requests/page', hall: 'cambridge', cursor: 'broken'
    expect(last_response.status).to eq(400)
    get '/api/category/service_requests/map', hall: 'cambridge', bbox: '-71.2,42.3,-71,42.5'
    expect(last_response.status).to eq(503)
    Muni::ServiceRequestMap.rebuild!
    get '/api/category/service_requests/map', hall: 'cambridge', bbox: '-71.2,42.3,-71,42.5'
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)['represented_count']).to eq(4)
    get '/api/category/service_requests/map', hall: 'cambridge', bbox: 'broken'
    expect(last_response.status).to eq(400)
  end
end
