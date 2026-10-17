require 'spec_helper'

RSpec.describe Muni::Water::MetricSnapshots do
  before { Muni::Store.ensure_tables! }

  def sample(id, **attrs)
    Muni::Water::Storage.db[:water_evidence].insert(
      { external_id: id, source_slug: 'water/charles/wqp', kind: 'laboratory', location_id: 'station',
        parameter: 'ecoli', unit: 'MPN/100mL', method: 'A', status: 'Final',
        observed_at: Time.utc(2026, 7, 1), payload: '{"routine_sample":true}' }.merge(attrs)
    )
  end

  it 'keeps QC and rejected samples out of latest readings without losing their records' do
    sample('routine')
    sample('replicate', observed_at: Time.utc(2026, 7, 2), payload: '{"routine_sample":false}')
    sample('rejected', observed_at: Time.utc(2026, 7, 3), status: 'Rejected')
    result = described_class.new.call
    expect(result[:samples].map { |row| row['external_id'] }).to eq(['routine'])
    expect(Muni::Water::Storage.evidence.count).to eq(3)
  end

  it 'keeps units and methods separate and preserves censored values and unknown sample types' do
    sample('mpn', payload: '{"routine_sample":true,"detection_condition":"Not Detected"}')
    sample('cfu', unit: 'cfu/100mL')
    sample('other-method', method: 'B')
    sample('dashboard', source_slug: 'water/charles/crwa_laboratory', payload: '{"routine_sample":null}')
    rows = described_class.new.call[:samples]
    expect(rows.length).to eq(4)
    expect(rows.find { |row| row['external_id'] == 'mpn' }.dig('payload', 'detection_condition')).to eq('Not Detected')
  end

  it 'keeps review and retraction totals separate from the latest usable discharge' do
    sample('notice', kind: 'discharge', source_slug: 'water/charles/cambridge_cso', status: 'published')
    sample('review', kind: 'discharge', source_slug: 'water/charles/cambridge_cso', status: 'needs_review')
    sample('withdrawn', kind: 'discharge', source_slug: 'water/charles/cambridge_cso', status: 'retracted')
    result = described_class.new.call[:discharges].first
    expect(result[:latest]['external_id']).to eq('notice')
    expect(result).to include(needs_review: 1, retracted: 1)
  end

  it 'selects a newer date-only notice without inventing a time or preferring an older timed notice' do
    source = 'water/charles/cambridge_cso'
    sample('timed', kind: 'discharge', source_slug: source, status: 'published')
    sample('date-only', kind: 'discharge', source_slug: source, status: 'published', observed_at: nil,
                       observed_date: '2026-07-02', time_precision: 'date',
                       payload: '{"event_date":"2026-07-02","time_precision":"date","countable":true}')
    result = described_class.new.call[:discharges].find { |row| row[:source_slug] == source }[:latest]
    expect(result).to include('external_id' => 'date-only', 'observed_at' => nil, 'observed_date' => '2026-07-02')
  end
end
