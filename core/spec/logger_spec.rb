require 'spec_helper'

RSpec.describe Muni::Logger do
  it 'redacts credential fields and URL credentials from diagnostics' do
    input = 'Authorization: Bearer synthetic-value token=synthetic-token ' \
            'https://user:synthetic-password@example.test/path?api_key=synthetic-key'
    output = described_class.redact(input)
    expect(output).not_to include('synthetic-', 'user:')
    expect(output).to include('Authorization: [REDACTED]', 'https://[REDACTED]@example.test/path')
  end

  it 'redacts configured secrets even when an upstream error omits their field names' do
    allow(ENV).to receive(:each_pair).and_yield('MUNI_SESSION_SECRET', 'synthetic-configured-secret')
    expect(described_class.redact('rejected synthetic-configured-secret')).to eq('rejected [REDACTED]')
  end

  it 'preserves ordinary operational messages' do
    expect(described_class.redact('Collected 42 records in 3 seconds')).to eq('Collected 42 records in 3 seconds')
  end
end
