require 'spec_helper'

RSpec.describe Muni::Water::Storage do
  it 'adds the source-date index to an existing evidence table without replacing its records' do
    Muni::Store.ensure_tables!
    db = described_class.db
    db[:water_evidence].insert(external_id: 'historical-date-only', source_slug: 'water/charles/crwa_laboratory',
                               observed_date: '2005-07-19')
    db.drop_index(:water_evidence, [:observed_date])
    expect(db.fetch("PRAGMA index_list('water_evidence')").map { |row| row[:name] })
      .not_to include('water_evidence_observed_date_index')

    2.times { Muni::Store.with_writer { described_class.ensure_tables! } }

    expect(db.fetch("PRAGMA index_info('water_evidence_observed_date_index')").map { |row| row[:name] })
      .to eq(['observed_date'])
    expect(db[:water_evidence].where(external_id: 'historical-date-only').get(:observed_date)).to eq('2005-07-19')
  end
end
