require 'spec_helper'

RSpec.describe Muni::Water::SpillBuffer do
  it 'spills large staged publications and replays them exactly without keeping original object graphs' do
    buffer = described_class.new(limit: 128)
    records = 12.times.map { |i| { id: i, body: 'evidence' * 100, time: Time.utc(2026, 10, 17) } }
    records.each { |record| buffer << record }
    expect(buffer.length).to eq(12)
    expect(buffer.to_a).to eq(records)
    expect(buffer.to_a).to eq(records)
    expect(buffer.instance_variable_get(:@memory)).to be_empty
    path = buffer.instance_variable_get(:@file).path
    buffer.close
    expect(File.exist?(path)).to be(false)
  ensure
    buffer&.close
  end
end
