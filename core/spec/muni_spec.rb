require 'spec_helper'

RSpec.describe Muni do
  it 'exposes a semver version string' do
    expect(Muni::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end
end
