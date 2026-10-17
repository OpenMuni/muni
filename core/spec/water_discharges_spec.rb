require 'spec_helper'

RSpec.describe Muni::Water::Adapters::Discharges do
  let(:now) { Time.utc(2026, 10, 16, 20) }
  let(:source) { described_class.new(id: 'cambridge_cso', now: now) }
  let(:row) do
    { 'date' => '10.11.2026', 'outfall' => "CAM005 | (Revised)\u00a0", 'water' => 'Charles River',
      'start' => '11:45 pm', 'stop' => '12:15 am', 'volume' => '0.14 MG | 0.22 MG (average of last three years)',
      'rainfall' => '1.2' }
  end

  before { Muni::Store.ensure_tables! }

  def event(input = row)
    source.send(:event, input, operator: 'City of Cambridge')
  end

  def import(events)
    client = instance_double(Muni::Water::Client, responses: [], validators: {})
    adapter = instance_double(Muni::Water::Adapters::Base, collect: events, locations: [], metadata: {},
                              checkpoint: {}, client: client)
    Muni::Water::Ingestor.new('cambridge_cso', now: now).run(adapter: adapter)
  end

  it 'keeps midnight crossings, canonical outfalls, event estimates and historical averages distinct' do
    record = event
    expect(record[:location_id]).to eq('CAM005')
    expect(Time.iso8601(record[:payload][:ends_at]) - record[:observed_at]).to eq(1800)
    expect(record[:value]).to eq(0.14)
    expect(record[:payload][:historical_average]).to include('0.22')
    expect(record[:payload][:rainfall]).to eq('1.2')
  end

  it 'does not interpret historical averages, censored volumes, or retractions as event measurements' do
    expect(event(row.merge('volume' => '0.22 MG (average of last three years)'))[:value]).to be_nil
    expect(event(row.merge('volume' => '<0.01 MG'))[:value]).to be_nil
    record = event(row.merge('date' => '10.11.2026 (retracted - no activation)'))
    expect(record[:status]).to eq('retracted')
    expect(record[:payload][:countable]).to be(false)
  end

  it 'reconciles uniquely shared notice documents and sends ambiguous matches to review' do
    documented = row.merge('notice_urls' => ['https://www.cambridgema.gov/activation.pdf'])
    import([event(documented)])
    import([event(documented.merge('stop' => '12:30 am'))])
    expect(Muni::Water::Storage.evidence.count).to eq(1)
    expect(Muni::Water::Storage.db[:water_revisions].count).to eq(2)
    import([event(documented.merge('stop' => '12:30 am'))])
    expect(Muni::Water::Storage.db[:water_revisions].count).to eq(2)
    import([event(documented.merge('start' => '10:00 pm')), event(documented.merge('start' => '9:00 pm'))])
    reviewed = Muni::Water::Storage.evidence.where(status: 'needs_review').all
    expect(reviewed.length).to eq(2)
    expect(reviewed.map { |record| JSON.parse(record[:payload])['countable'] }).to eq([false, false])
  end

  it 'retains distinct same-day publications when no source identity proves a correction' do
    import([event])
    import([event(row.merge('start' => '10:00 pm'))])
    expect(Muni::Water::Storage.evidence.count).to eq(2)
    expect(Muni::Water::Storage.evidence.where(status: 'needs_review').count).to eq(1)
    expect(Muni::Water::Storage.db[:water_revisions].select_map(:version)).to eq([1, 1])
  end
end
