require 'spec_helper'

RSpec.describe Muni::Water::Normalization, '.call' do
  let(:now) { Time.utc(2026, 10, 17) }
  let(:adapter) { Muni::Water::Adapters::CrwaLaboratory.new(id: 'crwa_laboratory', now: now) }
  let(:raw) do
    { 'FID' => 6237, 'GlobalID' => 'retained-publication', 'Site_ID' => '700S',
      'Date_Collected' => 1_121_731_200_000, 'Reporting_Result' => 10, 'Unit_Abbreviation' => 'cfu/100mL' }
  end
  let(:fresh) { adapter.send(:sample, raw) }
  let(:retained) do
    adapter.record(id: raw['GlobalID'], kind: 'laboratory', location_id: 'CRWA-700S', reach_id: '2',
                   observed_at: Time.at(raw['Date_Collected'] / 1000.0).utc, parameter: 'ecoli', value: 10.0,
                   unit: raw['Unit_Abbreviation'], original_timezone: 'UTC', method: placeholder, raw: raw,
                   payload: { time_precision: 'date', routine_sample: nil, original_value: raw['Reporting_Result'],
                     original_unit: raw['Unit_Abbreviation'],
                     publication_overlap: 'May also appear in WQP; not pooled in statistics.' })
  end

  before { Muni::Store.ensure_tables! }

  def placeholder = 'Published CRWA dashboard; laboratory method not supplied'

  it 'produces identical normalized evidence from the old importer label and an unchanged fresh publication' do
    normalized = described_class.call(retained)
    expect(normalized).to eq(fresh)
    expect(normalized[:method]).to be_nil
    expect(normalized[:payload][:method_status]).to eq('not_supplied')
    expect(normalized[:raw]).to eq(raw)
    expect(retained[:method]).to eq(placeholder)
  end

  it 'also removes the importer label from a previously normalized payload without altering real methods' do
    old_normalized = fresh.merge(payload: fresh[:payload].merge(method_description: placeholder))
    expect(described_class.call(old_normalized)).to eq(fresh)

    supplied = fresh.merge(method:  'Published CRWA laboratory method 1603',
                           payload: fresh[:payload].merge(method_description: 'Publisher supplied method note'))
    result = described_class.call(supplied)
    expect(result[:method]).to eq('Published CRWA laboratory method 1603')
    expect(result[:payload][:method_description]).to eq('Publisher supplied method note')
    expect(result[:payload][:method_status]).to eq('supplied')
  end

  it 'does not revise an unchanged normalized publication, but retains an actual publisher correction' do
    writer = Muni::Water::EvidenceWriter.new(now: now)
    expect(writer.call([retained])).to eq(1)
    original = Muni::Water::Storage.db[:water_revisions].first
    expect(writer.call([fresh.merge(fetched_at: now + 60)])).to eq(0)
    expect(Muni::Water::Storage.db[:water_revisions].all).to eq([original])

    corrected = adapter.send(:sample, raw.merge('Reporting_Result' => 12), fetched_at: now + 120)
    expect(writer.call([corrected])).to eq(1)
    expect(Muni::Water::Storage.evidence.first[:value]).to eq(12)
    expect(Muni::Water::Storage.db[:water_revisions].count).to eq(2)
    expect(writer.changes.first[:before]['value']).to eq(10)
    expect(writer.changes.first[:after][:payload][:change_kind]).to eq('publication')
  end
end
