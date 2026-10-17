require 'spec_helper'

RSpec.describe Muni::Registry do
  it 'indexes the shipped Cambridge launch records' do
    expect(described_class.record('service_requests')).to eq(Muni::Records::ServiceRequest)
    expect(described_class.record('trees')).to eq(Muni::Records::Tree)
  end
end
