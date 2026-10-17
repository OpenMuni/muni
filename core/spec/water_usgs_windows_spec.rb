require 'spec_helper'

RSpec.describe Muni::Water::Adapters::Usgs do
  let(:storage) { Muni::Water::Storage }
  let(:slug) { 'water/charles/usgs' }
  let(:windows) { [] }

  before do
    Muni::Store.ensure_tables!
    stub_request(:get, %r{api\.waterdata\.usgs\.gov/ogcapi/v1/collections/continuous/items}).to_return do |request|
      params = URI.decode_www_form(request.uri.query).to_h
      start, finish = params.fetch('datetime').split('/').map { |value| Time.iso8601(value) }
      windows << [start, finish]
      row = { 'monitoring_location_id' => 'USGS-01104500', 'time_series_id' => params['parameter_code'],
              'time' => finish.iso8601, 'last_modified' => Time.now.utc.iso8601,
              'parameter_code' => params['parameter_code'], 'value' => 1,
              'unit_of_measure' => 'ft', 'approval_status' => 'Provisional' }
      { body: JSON.generate(features: [{ properties: row }], links: []) }
    end
  end

  def collect_at(now)
    allow(Time).to receive(:now).and_return(now)
    Muni::Water::Ingestor.new('usgs', now: now).run
  end

  it 'publishes complete bounded windows and advances monthly reconciliation only after the last window' do
    now = Time.utc(2026, 1, 20, 20, 10)
    expect(collect_at(now)[:error]).to be_nil
    expect(storage.checkpoint(slug)).not_to have_key('reconciled_month')
    expect(storage.checkpoint(slug)['history_cursor']).to eq((now - (7 * 86_400)).iso8601)
    expect(collect_at(now + 5)[:error]).to be_nil
    expect(storage.checkpoint(slug)).not_to have_key('reconciled_month')
    expect(collect_at(now + 10)[:error]).to be_nil

    expect(storage.checkpoint(slug)['reconciled_month']).to eq('2026-01')
    expect(storage.checkpoint(slug).dig('metadata', 'backfill_pending')).to be(false)
    expect(windows.all? { |start, finish| finish - start <= 7 * 86_400 }).to be(true)
    expect(storage.evidence.count).to eq(6)
  end

  it 'refreshes recent readings before continuing history when the hourly publisher check becomes due' do
    now = Time.utc(2026, 1, 20, 20, 10)
    expect(collect_at(now)[:error]).to be_nil
    cursor = storage.checkpoint(slug)['history_cursor']
    later = Time.utc(2026, 1, 20, 20, 50)

    expect(collect_at(later)[:error]).to be_nil

    expect(windows.last).to eq([later - (7 * 86_400), later])
    expect(storage.checkpoint(slug)['history_cursor']).to eq(cursor)
    expect(storage.checkpoint(slug).dig('metadata', 'full_reconciliation')).to be(false)
  end

  it 'removes completed history cursors and never repeats the final old window' do
    now = Time.utc(2026, 1, 20, 20, 10)
    [now, now + 5, now + 10].each { |at| expect(collect_at(at)[:error]).to be_nil }
    expect(storage.checkpoint(slug).keys).not_to include('history_cursor', 'history_start', 'history_month')
    expect(collect_at(now + 15)[:error]).to be_nil
    expect(windows.last).to eq([now + 15 - (7 * 86_400), now + 15])
    expect(storage.checkpoint(slug).dig('metadata', 'backfill_pending')).to be(false)
    expect(storage.checkpoint(slug)['reconciled_month']).to eq('2026-01')
  end
end
