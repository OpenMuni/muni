require 'spec_helper'

RSpec.describe Muni::Water::Reconciler do
  before { Muni::Store.ensure_tables! }

  it 'reinterprets retained publications without advancing publisher check times or losing source records' do
    now = Time.utc(2026, 10, 16)
    row = Muni::Water::Adapters::Base.new(id: 'epa_buoy', now: now).record(
      id: 'reading', kind: 'sensor', location_id: 'epa-buoy', parameter: 'temperature',
      unit: '°C', observed_at: now, value: 15, raw: { temperature: '15' }
    )
    storage = Muni::Water::Storage
    Muni::Store.with_writer do
      Muni::Water::EvidenceWriter.new(now: now).call([row])
      storage.save_checkpoint(row[:source_slug], 'last_success_at' => now.iso8601)
    end
    count = storage.db[:water_revisions].count
    report = described_class.new(now: now + 3600).normalize
    expect(report[:before]).to eq(report[:after])
    expect(storage.evidence.first[:external_id]).to eq(row[:external_id])
    expect(storage.checkpoint(row[:source_slug])['last_success_at']).to eq(now.iso8601)
    expect(storage.db[:water_revisions].count).to eq(count)
    expect(described_class.new(now: now + 7200).normalize[:changed]).to eq(0)
  end
end
