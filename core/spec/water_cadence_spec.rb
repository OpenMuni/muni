require 'spec_helper'

RSpec.describe Muni::Water::Adapters::CrwaLaboratory do
  let(:now) { Time.utc(2026, 10, 16, 20) }
  let(:edition) { 1_786_143_656_731 }
  let(:storage) { Muni::Water::Storage }
  let(:slug) { 'water/charles/crwa_laboratory' }
  let(:url) { Muni::Water::Catalog::ARCGIS }

  before { Muni::Store.ensure_tables! }

  def layer(marker)
    stub_request(:get, url).with(query: { 'f' => 'json' })
                           .to_return(body: JSON.generate(editingInfo: { lastEditDate: marker }))
  end

  def feature(id = 1, value = 84)
    { attributes: { FID: id, GlobalID: "publication-#{id}", Site_ID: '1NBS',
                    Date_Collected: 1_764_806_400_000, Reporting_Result: value,
                    Unit_Abbreviation: 'cfu/100mL' } }
  end

  def page(features, offset: 0, more: false)
    stub_request(:get, "#{url}/query")
      .with(query: hash_including('resultOffset' => offset.to_s, 'resultRecordCount' => '1000'))
      .to_return(body: JSON.generate(features: features, exceededTransferLimit: more))
  end

  def collect(at: now)
    Muni::Water::Ingestor.new('crwa_laboratory', now: at).run
  end

  def initial_collection
    layer(edition)
    page([feature])
    expect(collect[:error]).to be_nil
  end

  def wqp_responses
    station_headers = %w[Location_Identifier Location_Name Location_Latitude Location_Longitude]
    result_headers = %w[Location_Identifier Activity_StartDate Result_MeasureIdentifier Result_Measure
                        Activity_StartTime Activity_StartTimeZone Activity_TypeCode Result_MeasureUnit]
    stations = CSV.generate do |csv|
      csv << station_headers
      csv << ['CRWA-1NBS', 'North Beacon St. Bridge-Center', '42.3589', '-71.1619']
    end
    results = CSV.generate do |csv|
      csv << result_headers
      csv << ['CRWA-1NBS', '2025-10-16', 'STORET-1100544807', '380', '09:33:00', 'EST',
              'Sample-Routine', 'cfu/100mL']
    end
    [stations, results]
  end

  it 'keeps measurement coverage independent of the slower publication checks' do
    definitions = Muni::Water::Catalog::DEFINITIONS
    expect(definitions.fetch('epa_buoy').values_at(:cadence, :interval, :grace)).to eq([1800, 900, 7200])
    expect(definitions.fetch('usgs').values_at(:cadence, :interval)).to eq([3600, 900])
    expect(definitions.fetch('wqp')[:cadence]).to eq(604_800)
  end

  it 'checks an unchanged archive without fetching its pages or refreshing its observations' do
    initial_collection
    checkpoint = storage.checkpoint(slug)
    expect(checkpoint['archive_edition']).to eq(edition)
    expect(checkpoint['reconciled_month']).to eq('2026-10')
    expect(checkpoint.dig('metadata', 'full_reconciliation')).to be(true)
    previous_records = storage.evidence.all
    previous_revisions = storage.db[:water_revisions].count

    result = collect(at: now + 86_400)

    expect(result.values_at(:rows_in, :rows_upserted, :error)).to eq([0, 0, nil])
    expect(storage.evidence.all).to eq(previous_records)
    expect(storage.db[:water_revisions].count).to eq(previous_revisions)
    expect(a_request(:get, url).with(query: { 'f' => 'json' })).to have_been_made.times(3)
    expect(a_request(:get, "#{url}/query").with(query: hash_including('f' => 'json'))).to have_been_made.once
  end

  it 'retains archive context on unchanged checks without presenting old samples as current' do
    initial_collection
    checkpoint = storage.checkpoint(slug)
    checkpoint['metadata']['publisher_note'] = 'Keep the archive context.'
    storage.save_checkpoint(slug, checkpoint)

    expect(collect(at: now + 86_400)[:error]).to be_nil

    current = storage.checkpoint(slug)
    expect(current['last_success_at']).to eq((now + 86_400).iso8601)
    expect(current.dig('metadata', 'publisher_note')).to eq('Keep the archive context.')
    expect(current.dig('metadata', 'unchanged_source')).to be(true)
    expect(current.dig('metadata', 'full_reconciliation')).to be(false)
    expect(current.dig('metadata', 'last_full_reconciliation_at'))
      .to eq(checkpoint.dig('metadata', 'last_full_reconciliation_at'))
    coverage = Muni::Water::Query.new(now: now + 86_400).coverage.find { |source| source[:id] == 'crwa_laboratory' }
    expect(coverage[:status]).to eq('historical_data_only')
    expect(coverage[:collection_status]).to eq('checking')
  end

  it 'retrieves a changed publisher edition and preserves the earlier publication version' do
    initial_collection
    layer(edition + 1000)
    page([feature(1, 90), feature(2, 100)])

    expect(collect(at: now + 86_400)[:error]).to be_nil

    expect(storage.evidence.count).to eq(2)
    expect(storage.db[:water_revisions].count).to eq(3)
    expect(storage.checkpoint(slug)['archive_edition']).to eq(edition + 1000)
    expect(a_request(:get, "#{url}/query").with(query: hash_including('f' => 'json'))).to have_been_made.twice
  end

  it 'reconciles monthly even when the publisher edition is unchanged' do
    initial_collection
    page([feature(1, 90)])

    expect(collect(at: Time.utc(2026, 11, 1))[:error]).to be_nil

    expect(storage.evidence.first[:value]).to eq(90)
    expect(storage.checkpoint(slug)['reconciled_month']).to eq('2026-11')
    expect(a_request(:get, "#{url}/query").with(query: hash_including('f' => 'json'))).to have_been_made.twice
  end

  it 'refreshes a changed station selection despite an unchanged publisher edition' do
    initial_collection
    checkpoint = storage.checkpoint(slug)
    checkpoint['archive_signature'] = 'previous-station-selection'
    storage.save_checkpoint(slug, checkpoint)
    page([feature, feature(2)])

    expect(collect(at: now + 86_400)[:error]).to be_nil

    expect(storage.evidence.count).to eq(2)
    expect(storage.checkpoint(slug)['archive_signature']).not_to eq('previous-station-selection')
    expect(a_request(:get, "#{url}/query").with(query: hash_including('f' => 'json')).with do |request|
      query = URI.decode_www_form(request.uri.query).to_h
      query['where'].include?("'1NBS'") && !query['where'].include?("'1NBC'")
    end).to have_been_made.twice
    expect(storage.evidence.select_map(:location_id).uniq).to eq(['CRWA-1NBS'])
    expect(storage.evidence.select_map(:reach_id).uniq).to eq(['2'])
  end

  [nil, 0, -1, '1786143656731', 1_786_143_656_731.5].each do |marker|
    it "retrieves archive data when the edit marker is invalid: #{marker.inspect}" do
      initial_collection
      layer(marker)
      page([feature(1, 90)])

      expect(collect(at: now + 86_400)[:error]).to be_nil

      expect(storage.evidence.first[:value]).to eq(90)
      expect(a_request(:get, "#{url}/query").with(query: hash_including('f' => 'json'))).to have_been_made.twice
    end
  end

  it 'does not promote an edition or partial observations when a later page fails' do
    initial_collection
    checkpoint = storage.checkpoint(slug)
    previous_records = storage.evidence.all
    layer(edition + 1000)
    page([feature(1, 90)], more: true)
    stub_request(:get, "#{url}/query").with(query: hash_including('resultOffset' => '1'))
                                      .to_return(body: JSON.generate(error: { message: 'Source page unavailable' }))

    result = collect(at: now + 86_400)

    expect(result[:error]).to be_a(Muni::Water::Error)
    expect(storage.checkpoint(slug)).to eq(checkpoint)
    expect(storage.evidence.all).to eq(previous_records)
    expect(storage.db[:water_revisions].count).to eq(1)
    expect(storage.db[:water_runs].order(:id).last[:status]).to eq('failed')
  end

  it 'requests the published North Beacon station from WQP and retains its reach' do
    stations, results = wqp_responses
    base = Muni::Water::Catalog::WQP
    stub_request(:get, "#{base}/Station/search").with(query: hash_including('organization' => 'CRWA'))
                                                .to_return(body: stations)
    request = stub_request(:get,
                           "#{base}/Result/search").with(query: hash_including('organization' => 'CRWA')) do |incoming|
      sites = URI.decode_www_form(incoming.uri.query).to_h.fetch('siteid').split(';')
      sites.include?('CRWA-1NBS') && !sites.include?('CRWA-1NBC')
    end.to_return(body: results)

    result = Muni::Water::Ingestor.new('wqp', now: now).run

    expect(result[:error]).to be_nil
    expect(request).to have_been_requested.once
    expect(storage.evidence.first.values_at(:location_id, :reach_id, :value)).to eq(['CRWA-1NBS', '2', 380])
    expect(storage.locations.any? { |location| location['id'] == 'CRWA-1NBS' }).to be(true)
  end

  it 'restarts from fresh pages when the archive edition changes during pagination' do
    markers = [edition, edition + 1000, edition + 1000, edition + 1000]
    stub_request(:get, url).with(query: { 'f' => 'json' }).to_return(
      *markers.map { |marker| { body: JSON.generate(editingInfo: { dataLastEditDate: marker }) } }
    )
    stub_request(:get, "#{url}/query").with(query: hash_including('resultOffset' => '0')).to_return(
      { body: JSON.generate(features: [feature(1, 84)]) },
      { body: JSON.generate(features: [feature(1, 90)]) }
    )

    expect(collect[:error]).to be_nil

    expect(storage.evidence.select_map(:value)).to eq([90])
    expect(storage.checkpoint(slug)['archive_edition']).to eq(edition + 1000)
    expect(a_request(:get, "#{url}/query").with(query: hash_including('resultOffset' => '0'))).to have_been_made.twice
  end

  it 'discards a failed earlier edition before resuming an archive with a newer edit marker' do
    layer(edition)
    page([feature(1, 84)], more: true)
    stub_request(:get, "#{url}/query").with(query: hash_including('resultOffset' => '1'))
                                      .to_return(status: 503, body: 'Page unavailable')
    expect(collect[:error]).to be_a(Muni::Helpers::Http::Error)
    expect(storage.evidence.count).to eq(0)
    expect(storage.db[:water_pending_pages].where(source_slug: slug).count).to be_positive

    layer(edition + 1000)
    page([feature(1, 90)])

    expect(collect(at: now + 3600)[:error]).to be_nil

    expect(storage.evidence.select_map(:value)).to eq([90])
    expect(storage.checkpoint(slug)['archive_edition']).to eq(edition + 1000)
    expect(a_request(:get, "#{url}/query").with(query: hash_including('resultOffset' => '0'))).to have_been_made.twice
  end

  it 'defers a continuously changing archive after two restarts without publishing mixed editions' do
    markers = [edition, edition + 1000, edition + 1000, edition + 2000, edition + 2000, edition + 3000]
    stub_request(:get, url).with(query: { 'f' => 'json' }).to_return(
      *markers.map { |marker| { body: JSON.generate(editingInfo: { lastEditDate: marker }) } }
    )
    page([feature])

    result = collect

    expect(result[:error]).to be_a(Muni::Water::Error)
    expect(result[:error].message).to include('changed during pagination')
    expect(result[:error].retryable?).to be(true)
    expect(result[:error].retry_at).to be_nil
    expect(storage.evidence.count).to eq(0)
    expect(storage.checkpoint(slug)).to eq({})
    expect(a_request(:get,
                     "#{url}/query").with(query: hash_including('resultOffset' => '0'))).to have_been_made.times(3)
  end
end
