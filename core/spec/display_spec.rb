require 'spec_helper'

RSpec.describe Muni::Display do
  it 'publishes a browser-safe display contract keyed by record type' do
    contract = described_class.contract

    expect(contract[:title_fields]['PoliceLogEntry']).to eq(
      %w[crime_subcategory description crime_category external_id]
    )
    expect(contract[:subtitle_fields]['ServiceRequest']).to eq(
      %w[description neighborhood department]
    )
    expect(contract[:field_labels]['source_url']).to eq('Source')
    expect(contract[:title_fields]['FoodTruck']).to eq(
      %w[truck_name dba business_name external_id]
    )
  end

  it 'keeps row metadata definitions in the shared display layer' do
    contract = described_class.contract

    expect(contract[:meta_fields]['Crash']).to include(
      'label'     => 'Status',
      'synthetic' => 'crash_status',
      'tone'      => 'status'
    )
    expect(contract[:meta_fields]['Tree']).to include(
      'label'   => 'Scientific',
      'field'   => 'species_scientific',
      'require' => 'scientific_name'
    )
    expect(contract[:meta_fields]['FoodTruck']).to include(
      'label' => 'Hours',
      'field' => 'hours'
    )
  end
end
