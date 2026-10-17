require 'spec_helper'

RSpec.describe Muni::CLI::Router do
  def capture
    out = StringIO.new
    err = StringIO.new
    orig_out = $stdout
    orig_err = $stderr
    $stdout = out
    $stderr = err
    code = yield
    [code, out.string, err.string]
  ensure
    $stdout = orig_out
    $stderr = orig_err
  end

  it 'prints the version on --version' do
    code, out, = capture { described_class.new(['--version']).call }
    expect(code).to eq(0)
    expect(out.strip).to eq(Muni::VERSION)
  end

  it 'prints help with no args' do
    code, out, = capture { described_class.new([]).call }
    expect(code).to eq(0)
    expect(out).to include('Usage: muni')
  end

  it 'returns non-zero on unknown commands' do
    code, _, err = capture { described_class.new(['nope']).call }
    expect(code).to eq(1)
    expect(err).to match(/unknown (?:command|namespace)/)
  end

  it 'filters removed source cursors from data status' do
    Muni.boot!
    Muni::Hall.load_all!
    Muni::Store.ensure_tables!
    now = Time.utc(2026, 6, 14, 12, 0, 0)
    Muni::Store.upsert(service_request('cambridge', 'sr/cambridge', now))
    Muni::Store.upsert(service_request('legacy', 'sr/legacy', now))
    Muni::Store.bump_seen('cambridge/service_requests', now)
    Muni::Store.bump_seen('legacy/service_requests', now)

    code, out, = capture { described_class.new(%w[data status --json -y]).call }

    expect(code).to eq(0)
    body = JSON.parse(out)
    expect(body['cursors'].map { |row| row['source'] }).to eq(['cambridge/service_requests'])
    service_requests = body['counts'].find { |row| row['record'] == 'service_requests' }
    expect(service_requests['rows']).to eq(1)
    expect(body).to eq(JSON.parse(JSON.dump(Muni::Data.status)))
  end

  it 'uses the shared data service for records commands' do
    Muni.boot!
    Muni::Hall.load_all!
    Muni::Store.ensure_tables!
    Muni::Store.db[:service_requests].delete
    Muni::Store.upsert(service_request('cambridge', 'sr/shared-records', Time.utc(2026, 6, 14, 12, 0, 0)))

    code, out, = capture do
      described_class.new(%w[records ls service_requests --hall=cambridge --limit=5 --json -y]).call
    end

    expected = Muni::Data.records_for_type('service_requests', hall: 'cambridge', limit: 5)
    expect(code).to eq(0)
    expect(JSON.parse(out)).to eq(JSON.parse(JSON.dump(expected)))

    code, out, = capture do
      described_class.new(%w[records show service_requests --id=sr/shared-records --json -y]).call
    end

    expected = Muni::Data.record_for_type('service_requests', id: 'sr/shared-records')
    expect(code).to eq(0)
    expect(JSON.parse(out)).to eq(JSON.parse(JSON.dump(expected)))
  end

  it 'runs and shows cached analytics as json' do
    code, out, = capture { described_class.new(%w[analytics run --hall=cambridge --json -y]).call }

    expect(code).to eq(0)
    body = JSON.parse(out)
    expect(body).to include('status', 'service_requests', 'crash_risks')

    code, out, = capture { described_class.new(%w[analytics show --hall=cambridge --json -y]).call }

    expect(code).to eq(0)
    body = JSON.parse(out)
    expect(body['service_requests']).to include('status')
  end

  it 'scopes Hall seed counts to the requested municipality' do
    allow(Muni::Beats).to receive(:run_all_once!).with(hall: 'boston').and_return(
      [{ slug: 'boston/service_requests', rows_in: 2, rows_upserted: 2, error: nil }]
    )
    allow(Muni::Store).to receive(:counts_by_source).with(hall: 'boston').and_return(
      'boston/service_requests' => 2
    )

    code, out, = capture { described_class.new(%w[beats seed --hall=boston --json -y]).call }
    body = JSON.parse(out)

    expect(code).to eq(0)
    expect(body['counts']).to eq('boston/service_requests' => 2)
    expect(body['results'].map { |row| row['slug'] }).to eq(['boston/service_requests'])
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
