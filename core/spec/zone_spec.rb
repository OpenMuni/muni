require 'spec_helper'

RSpec.describe Muni::Zone do
  before { Muni::Hall.load_all! }

  it 'parses a hall slug' do
    z = described_class.parse('cambridge')
    expect(z.slug).to eq('cambridge')
    expect(z.state).to eq('MA')
  end

  it 'parses city,state with comma or space' do
    expect(described_class.parse('cambridge,ma').slug).to eq('cambridge')
    expect(described_class.parse('Cambridge MA').slug).to eq('cambridge')
    expect(described_class.parse('boston,ma').slug).to eq('boston')
  end

  it 'raises on unknown zones' do
    expect { described_class.parse!('nopeville') }.to raise_error(described_class::Unknown)
    expect { described_class.parse!(nil) }.to raise_error(described_class::Unknown)
  end
end
