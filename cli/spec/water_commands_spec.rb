require 'spec_helper'

RSpec.describe Muni::CLI::Router do
  def invoke(*arguments)
    output = StringIO.new
    original = $stdout
    $stdout = output
    status = Muni::CLI::Router.new(['water', *arguments, '--json', '-y']).call
    [status, JSON.parse(output.string)]
  ensure
    $stdout = original
  end

  it 'requests full reconciliation through the shared ingestion service' do
    ingestor = instance_double(Muni::Water::Ingestor)
    allow(Muni::Water::Ingestor).to receive(:new).with('epa_buoy').and_return(ingestor)
    allow(ingestor).to receive(:run).with(reconcile: true).and_return(rows_in: 10, rows_upserted: 0, error: nil)
    status, result = invoke('reconcile', 'water/charles/epa_buoy')
    expect(status).to eq(0)
    expect(result).to include('rows_in' => 10, 'error' => nil)
    expect(ingestor).to have_received(:run).with(reconcile: true)
  end

  it 'uses the same overview selection service as the web API' do
    query = instance_double(Muni::Water::Query, metrics: { policy_version: 'test', metrics: [] })
    allow(Muni::Water::Query).to receive(:new).and_return(query)
    status, result = invoke('metrics')
    expect(status).to eq(0)
    expect(result).to eq('policy_version' => 'test', 'metrics' => [])
  end
end
