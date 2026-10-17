require 'spec_helper'

RSpec.describe Muni::Water::Adapters::Buoy do
  let(:url) { Muni::Water::Catalog::BUOY }
  let(:body) { File.read(File.expand_path('../../spec/fixtures/water/buoy.csv', __dir__)) }

  before { Muni::Store.ensure_tables! }

  def source(checkpoint = {})
    described_class.new(id: 'epa_buoy', checkpoint: checkpoint, client: Muni::Water::Client.new(checkpoint))
  end

  it 'expands only changed source rows while retaining corrections to old observations' do
    stub_request(:get, url).to_return(body: body)
    first = source
    original = first.collect
    changed_body = body.sub('21.2', '22.2')
    stub_request(:get, url).to_return(body: changed_body)
    second = source(first.checkpoint)
    changed = second.collect

    expect(changed.length).to eq(10)
    expect(changed.find { |row| row[:parameter] == 'temperature' }[:value]).to eq(22.2)
    expect(original.length).to be > changed.length
    expect(second.metadata[:changed_source_rows]).to eq(1)
  end

  it 'skips an identical file and invalidates fingerprints when normalization changes' do
    stub_request(:get, url).to_return(body: body)
    first = source
    count = first.collect.length
    same = source(first.checkpoint)
    expect(same.collect).to be_empty
    old_parser = first.checkpoint.merge('buoy_row_parser' => 'older-normalizer')
    expect(source(old_parser).collect.length).to eq(count)
  end

  it 'rejects conflicting same-time rows before advancing the source-row checkpoint' do
    conflicting = body + body.lines[1].sub('21.2', '22.2')
    stub_request(:get, url).to_return(body: conflicting)
    source = described_class.new(id: 'epa_buoy')
    expect { source.collect }.to raise_error(Muni::Water::Error, /conflicting rows/)
    expect(source.checkpoint).not_to have_key('buoy_row_fingerprints')
  end

  it 'forces a full expansion past validators, fingerprints and an abandoned pending response' do
    stub_request(:get, url).to_return(body: body, headers: { 'ETag' => 'same-file' })
    stub_request(:get, url).with(headers: { 'If-None-Match' => 'same-file' }).to_return(status: 304)
    importer = Muni::Water::Ingestor.new('epa_buoy')
    first = importer.run
    expect(first[:rows_in]).to be_positive
    expect(importer.run[:rows_in]).to eq(0)
    Muni::Water::Storage.db[:water_pending_pages].insert(
      source_slug: importer.slug, url: url, retrieved_at: Time.now.utc, snapshot_at: Time.now.utc,
      headers: '{}', body: Sequel.blob(Zlib.gzip('abandoned response'))
    )
    refreshed = importer.run(reconcile: true)
    expect(refreshed).to include(error: nil, rows_in: first[:rows_in], rows_upserted: 0)
    expect(Muni::Water::Storage.db[:water_pending_pages].count).to eq(0)
    expect(a_request(:get, url).with { |request| !request.headers.key?('If-None-Match') }).to have_been_made.twice
  end

  it 'does not discard another running collector snapshot when reconciliation cannot acquire the source lock' do
    stub_request(:get, url).to_return(body: body)
    importer = Muni::Water::Ingestor.new('epa_buoy')
    Muni::Water::Client.new({}, slug: importer.slug).get(url)
    lock_path = "#{Muni::Config.db_path}.water-#{Muni::Water.hash(importer.slug)[0, 16]}.lock"
    File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      expect(importer.run(reconcile: true)[:error].message).to include('already running')
      expect(Muni::Water::Storage.db[:water_pending_pages].count).to eq(1)
      expect(a_request(:get, url)).to have_been_made.once
    end
  end
end
