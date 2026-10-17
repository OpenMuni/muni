require 'spec_helper'

RSpec.describe Muni::Water::Normalization do
  before { Muni::Store.ensure_tables! }

  let(:arcgis) { Muni::Water::Adapters::CrwaLaboratory.new(id: 'crwa_laboratory') }
  let(:wqp) { Muni::Water::Adapters::Wqp.new(id: 'wqp') }
  let(:raw) do
    { 'FID' => 6237, 'GlobalID' => 'publication-a', 'Site_ID' => '763S',
      'Date_Collected' => 1_121_731_200_000, 'Reporting_Result' => 10, 'Unit_Abbreviation' => 'cfu/100mL' }
  end

  def sample(role: 'Sample-Routine', value: '63', id: 'routine')
    wqp.send(:sample, { 'Location_Identifier' => 'CRWA-763S', 'Activity_StartDate' => '2025-12-09',
      'Activity_StartTime' => '06:15', 'Activity_StartTimeZone' => 'EST', 'Activity_TypeCode' => role,
      'Activity_ActivityIdentifier' => "CRWA-#{id}", 'Result_MeasureIdentifier' => id,
      'Result_Measure' => value, 'Result_MeasureUnit' => 'MPN/100mL',
      'Result_MeasureStatusIdentifier' => 'Accepted', 'Activity_Comment' => 'Moved because usual location was frozen',
      'Activity_Media' => 'Water', 'Activity_ActivityRelativeDepth' => 'Surface' })
  end

  it 'retains source dates without fabricating an observation instant or shifting them into the previous day' do
    record = arcgis.send(:sample, raw)
    expect(record.values_at(:observed_date, :time_precision, :observed_at)).to eq(['2005-07-19', 'date', nil])
    expect(record[:payload].dig(:source_provenance, :source_date_value)).to eq(1_121_731_200_000)
    expect(record[:raw]).to eq(raw)
    expect(raw).not_to have_key('observed_date')
    shifted = arcgis.send(:sample, raw.merge('Date_Collected' => raw['Date_Collected'] + 14_400_000))
    expect(shifted[:observed_date]).to eq('2005-07-19')
    expect(shifted[:payload][:publication_group_id]).not_to eq(record[:payload][:publication_group_id])
  end

  it 'groups exact ArcGIS publication copies without deleting their individual source identities' do
    records = [arcgis.send(:sample, raw),
               arcgis.send(:sample, raw.merge('FID' => 82_943, 'GlobalID' => 'publication-b'))]
    selected = Muni::Water::Eligibility.select(records)
    expect(selected.length).to eq(1)
    expect(selected.first['publication_count']).to eq(2)
    expect(selected.first['publication_ids']).to match_array(records.map { |row| row[:external_id] })
    expect(selected.first.dig('payload', 'identity_status')).to eq('publication_only')
    expect(Muni::Water::Eligibility.select(selected)).to eq(selected)
  end

  it 'keeps date-only WQP samples from acquiring a fabricated midnight source timestamp' do
    row = sample[:raw].merge('Activity_StartTime' => '')
    record = wqp.send(:sample, row)
    expect(record.values_at(:observed_at, :observed_date, :time_precision)).to eq([nil, '2025-12-09', 'date'])
    expect(record[:payload].dig(:source_provenance, :source_observed_at)).to be_nil
    expect(record[:payload].dig(:source_provenance, :source_date_value)).to eq('2025-12-09')
  end

  it 'keeps routine samples separate from their later quality-control replicates on every selection' do
    routine = sample
    replicate = sample(role: 'Quality Control Sample-Field Replicate', value: '74', id: 'replicate')
    selection = Muni::Water::Eligibility.primary([routine, replicate])
    expect(selection['routine'].map { |row| row['value'] }).to eq([63])
    expect(Muni::Water::Eligibility.project(replicate).dig('eligibility',
                                                           'reasons')).to include('quality_control_sample')
    expect(routine[:payload].dig(:sampling, :field_note)).to include('frozen')
    expect(routine[:payload].dig(:sampling, :medium)).to eq('Water')
  end

  it 'marks cross-feed equal-value matches as candidates and preserves the MPN/CFU conflict' do
    first = sample(value: '84')
    second = arcgis.send(:sample, raw.merge('Date_Collected'   => Time.utc(2025, 12, 9).to_i * 1000,
                                            'Reporting_Result' => 84))
    selected = Muni::Water::Eligibility.select([first, second])
    expect(selected.length).to eq(2)
    expect(selected.map { |row| row['unit'] }).to contain_exactly('MPN/100mL', 'cfu/100mL')
    expect(selected.map { |row| row['sample_candidates'].first['relation'] }.uniq)
      .to eq(['possible_same_sample_unit_conflict'])
    expect(selected.map { |row| row.dig('eligibility', 'calculation') }).to eq([false, false])
    expect(selected.map { |row| row.dig('eligibility', 'reasons') }.flatten)
      .to include('cross_source_unit_conflict')
  end

  it 'represents censored results as bounds and excludes them from exact-value calculations' do
    record = sample(value: '>1600')
    expect(record[:value]).to be_nil
    expect(record[:payload].values_at(:result_relation, :comparator, :limit_value)).to eq(['greater_than', '>', 1600])
    expect(record[:payload][:original_value]).to eq('>1600')
    expect(Muni::Water::Eligibility.calculable?(record)).to be(false)
    expect(Muni::Water::Eligibility.project(record).dig('eligibility', 'primary')).to be(true)
    unicode = sample(value: '≤10')
    expect(unicode[:payload].values_at(:comparator, :limit_value)).to eq(['<=', 10])
  end

  it 'does not turn a negative biological estimate into a zero or an eligible count' do
    record = described_class.call(kind: 'derived_sensor', parameter: 'estimated_cyanobacteria',
                                  value: -10_200, unit: 'cells/mL', status: 'provisional', raw: {}, payload: {})
    expect(record[:value]).to eq(-10_200)
    expect(record[:payload][:quality_flags]).to include('negative_biological_estimate')
    expect(record[:payload][:calculation_eligible]).to be(false)
  end

  it 'is idempotent and treats missing source method information as unknown rather than a laboratory method' do
    record = arcgis.send(:sample, raw)
    expect(described_class.call(record)).to eq(record)
    expect(record[:method]).to be_nil
    expect(record[:payload][:method_status]).to eq('not_supplied')
    expect(record[:payload][:sample_role]).to eq('unknown')
    expect(record[:normalization_version]).to eq(described_class::VERSION)
  end

  it 'preserves normalized lineage and context when a public response omits raw source fields' do
    first = Muni::Water::Eligibility.project(arcgis.send(:sample, raw))
    second = Muni::Water::Eligibility.project(arcgis.send(:sample, raw.merge('Reporting_Result' => 20, 'FID' => 2)))
    first.delete('raw')
    second.delete('raw')
    projected = Muni::Water::Eligibility.project(first)
    expect(projected['payload']).to eq(first['payload'])
    expect(Muni::Water::Eligibility.select([first, second]).length).to eq(2)
  end
end
