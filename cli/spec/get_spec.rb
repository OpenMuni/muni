require 'spec_helper'

RSpec.describe Muni::CLI::Get::Command do
  def capture(argv)
    out = StringIO.new
    err = StringIO.new
    orig_out = $stdout
    orig_err = $stderr
    $stdout = out
    $stderr = err
    code = Muni::CLI::Router.new(argv).call
    [code, out.string, err.string]
  ensure
    $stdout = orig_out
    $stderr = orig_err
  end

  before do
    Muni.boot!
    Muni::Hall.load_all!
  end

  it 'lists domains' do
    code, out, = capture(%w[get list --json -y])
    expect(code).to eq(0)
    rows = JSON.parse(out)
    expect(rows.map { |r| r['domain'] }).to eq(%w[
                                                 311 police crime_reports dispatch_calls permits crashes
                                                 recent_crashes traffic_volume bicycle_counts pedestrian_counts
                                                 parking trees parks food_trucks events
                                                 new_construction developments zoning_appeals meetings
                                               ])
    expect(rows.first.keys).to contain_exactly('domain', 'title', 'providers', 'zone')
  end

  it 'errors on unknown domains' do
    code, _, err = capture(%w[get notadomain -y])
    expect(code).to eq(1)
    expect(err).to include('unknown domain')
  end

  it 'serves cached records through the shared data service' do
    Muni::Store.ensure_tables!
    Muni::Store.db[:service_requests].delete
    Muni::Store.upsert(service_request('cambridge', 'sr/get-cached', Time.utc(2026, 6, 14, 12, 0, 0)))

    code, out, = capture(%w[get 311 --zone=cambridge,ma --cached --json -y])

    expect(code).to eq(0)
    body = JSON.parse(out)
    expected = Muni::Data.records_for_type('service_requests', hall: 'cambridge', limit: 25)
    expect(body['live']).to be(false)
    expect(body['records']).to eq(JSON.parse(JSON.dump(expected)))
  end

  def service_request(hall, external_id, opened_at)
    Muni::Records::ServiceRequest.new(
      external_id: external_id,
      hall:        hall,
      case_type:   'Pothole',
      status:      'Open',
      opened_at:   opened_at,
      source_url:  'https://example.com'
    )
  end
end
