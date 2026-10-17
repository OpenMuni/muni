require 'spec_helper'

RSpec.describe Muni::Get::Runner do
  before do
    Muni.boot!
    Muni::Hall.load_all!
  end

  it 'uses hall slug as provider for city domains' do
    stub = instance_double(Cambridge::ServiceRequests, pull: [])
    allow(Cambridge::ServiceRequests).to receive(:new).and_return(stub)

    zone = Muni::Zone.parse!('cambridge,ma')
    result = described_class.new(domain: :'311', zone: zone, live: true).call
    expect(result.provider).to eq(:cambridge)
    expect(result.source).to eq('cambridge/service_requests')
  end

  it 'uses Boston catalog providers and clearly rejects unsupported domains' do
    stub = instance_double(Boston::ServiceRequests, pull: [])
    allow(Boston::ServiceRequests).to receive(:new).and_return(stub)
    zone = Muni::Zone.parse!('boston,ma')

    result = described_class.new(domain: :'311', zone: zone, live: true).call

    expect(result.provider).to eq(:boston)
    expect(result.source).to eq('boston/service_requests')
    expect do
      described_class.new(domain: :police, zone: zone, live: true).call
    end.to raise_error(ArgumentError, /provider :boston not available for police/)
  end

  it 'errors when zone is required but missing' do
    expect do
      described_class.new(domain: :police, live: true).call
    end.to raise_error(ArgumentError, /requires a zone/)
  end
end
