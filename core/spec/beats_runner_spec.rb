require 'spec_helper'

RSpec.describe Muni::Beats do
  before do
    Muni.boot!
    Muni::Store.ensure_tables!
  end

  it 'runs every registered beat once' do
    Muni::Registry.beats.each_value do |klass|
      beat = instance_double(klass, run!: { rows_in: 1, rows_upserted: 1, error: nil })
      allow(klass).to receive(:new).and_return(beat)
    end
    results = described_class.run_all_once!
    expect(results.size).to eq(Muni::Registry.beats.size)
    expect(results.first).to include(:slug, :rows_in, :rows_upserted, :error)
  end
end
