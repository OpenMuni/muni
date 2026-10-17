require 'spec_helper'

RSpec.describe Muni::Water::Adapters::CambridgeCso do
  let(:pdf) { File.binread(File.expand_path('../../spec/fixtures/water/cambridge-2023-correction.pdf', __dir__)) }
  let(:link) { described_class::CORRECTION_URL }
  let(:notice) do
    '<table><tr><th>CSO Number</th></tr><tr><td>07.29.2023</td><td>CAM005</td>' \
      '<td>Charles River</td><td>Eliot Bridge</td><td>6:19pm</td><td>6:32pm</td>' \
      "<td>13 minutes</td><td>0.22 MG (average)</td><td>1.2</td><td><a href='#{link}'>Alert</a></td></tr></table>"
  end

  before do
    Muni::Store.ensure_tables!
    stub_const('Muni::Water::Adapters::CambridgeCso::CORRECTION',
               described_class::CORRECTION.merge(sha256: Digest::SHA256.hexdigest(pdf)))
  end

  def collect(body: pdf, html: notice)
    stub_request(:get, Muni::Water::Catalog::CAMBRIDGE).to_return(body: html)
    stub_request(:get, link).to_return(body: body, headers: { 'Content-Type' => 'application/pdf' })
    described_class.new(id: 'cambridge_cso').collect
  end

  it 'verifies the exact publisher correction before retracting CAM005 and recording omitted CAM017' do
    records = collect
    retracted = records.find { |row| row[:location_id] == 'CAM005' }
    omitted = records.find { |row| row[:location_id] == 'CAM017' }
    expect(retracted[:status]).to eq('retracted')
    expect(retracted[:payload][:countable]).to be(false)
    expect(omitted[:status]).to eq('published')
    expect(omitted[:payload].values_at(:event_date, :countable, :time_precision)).to eq(['2023-07-29', true, 'date'])
    expect(omitted[:value]).to be_nil
    expect(omitted[:payload][:corrections].first.values_at(:source_url, :sha256, :page))
      .to eq([link, Digest::SHA256.hexdigest(pdf), 1])
  end

  it 'requires review if the linked document changes and never creates an unverified omission' do
    records = collect(body: '%PDF-1.7 changed source document')
    expect(records.length).to eq(1)
    expect(records.first[:status]).to eq('needs_review')
    expect(records.first[:payload][:countable]).to be(false)
    expect(records.first[:payload][:correction_verification][:sha256]).not_to eq(described_class::CORRECTION[:sha256])
  end

  it 'restores published CAM017 table times once the explicit omission correction is verified' do
    source_row = notice[%r{<tr><td>.*</tr>}].sub('CAM005', 'CAM017').sub('6:19pm', '5:10pm').sub('6:32pm', '5:40pm')
    records = collect(html: notice.sub('</table>', "#{source_row}</table>"))
    expect(records.length).to eq(2)
    confirmed = Muni::Water::Normalization.call(records.find { |row| row[:location_id] == 'CAM017' })
    expect(confirmed).to include(status: 'published', observed_date: '2023-07-29', time_precision: 'time',
                                 observed_at: Time.utc(2023, 7, 29, 21, 10))
    expect(confirmed[:payload]).to include(countable: true, ends_at: '2023-07-29T21:40:00Z')
    retracted = Muni::Water::Normalization.call(records.find { |row| row[:location_id] == 'CAM005' })
    expect(retracted).to include(status: 'retracted', observed_at: nil, time_precision: 'date')
  end

  it 'does not use the omission correction to resolve multiple conflicting source times' do
    source_row = notice[%r{<tr><td>.*</tr>}].sub('CAM005', 'CAM017').sub('6:19pm', '5:10pm (5:20pm)')
    confirmed = collect(html: notice.sub('</table>', "#{source_row}</table>"))
                .find { |row| row[:location_id] == 'CAM017' }
    expect(confirmed).to include(status: 'needs_review')
    expect(confirmed[:payload]).to include(countable: false, time_precision: 'date')
  end

  it 'does not apply a correction to multiple possible targets' do
    duplicate = notice[%r{<tr><td>.*</tr>}].sub('6:19pm', '7:19pm')
    records = collect(html: notice.sub('</table>', "#{duplicate}</table>"))
    targets = records.select { |row| row[:location_id] == 'CAM005' }
    expect(targets.length).to eq(2)
    expect(targets.map { |row| row[:status] }.uniq).to eq(['needs_review'])
    expect(targets.all? { |row| row[:payload][:countable] == false }).to be(true)
  end

  it 'rechecks the linked document when the parent is unchanged and retains original retrieval dates' do
    parent = Muni::Water::Catalog::CAMBRIDGE
    storage = Muni::Water::Storage
    first_check = Time.utc(2026, 10, 16, 12)
    allow(Time).to receive(:now).and_return(first_check)
    stub_request(:get, parent).to_return(body: notice, headers: { 'ETag' => 'table-1' })
    stub_request(:get, link).to_return(body: pdf, headers: { 'ETag' => 'pdf-1' })
    expect(Muni::Water::Ingestor.new('cambridge_cso').run[:error]).to be_nil
    expect(storage.db[:water_revisions].count).to eq(2)
    stub_request(:get, parent).with(headers: { 'If-None-Match' => 'table-1' }).to_return(status: 304)
    stub_request(:get, link).with(headers: { 'If-None-Match' => 'pdf-1' })
                            .to_return(body: '%PDF-1.7 changed correction', headers: { 'ETag' => 'pdf-2' })
    allow(Time).to receive(:now).and_return(first_check + 900)

    result = Muni::Water::Ingestor.new('cambridge_cso').run

    expect(result[:error]).to be_nil
    expect(storage.evidence.select_map(:status)).to eq(%w[needs_review needs_review])
    expect(storage.evidence.select_map(:fetched_at).uniq).to eq([first_check + 900])
    expect(storage.db[:water_responses].where(url: parent).first[:retrieved_at]).to eq(first_check)
    expect(storage.db[:water_revisions].count).to eq(4)
    expect(a_request(:get, link)).to have_been_made.twice
  end

  it 'publishes a changed PDF after an older retained HTML body was fetched again before a 304' do
    parent = Muni::Water::Catalog::CAMBRIDGE
    storage = Muni::Water::Storage
    received = Time.utc(2026, 10, 16, 12)
    response = { url: parent, body: notice, retrieved_at: received, headers: { 'etag' => 'table-1' } }
    archived = Muni::Water::ResponseArchive.prepare('water/charles/cambridge_cso', [response], now: received)
    Muni::Water::ResponseArchive.publish('water/charles/cambridge_cso', archived, now: received)
    allow(Time).to receive(:now).and_return(received + 900)
    stub_request(:get, parent).to_return(body: notice, headers: { 'ETag' => 'table-1' })
    stub_request(:get, link).to_return(body: pdf, headers: { 'ETag' => 'pdf-1' })
    expect(Muni::Water::Ingestor.new('cambridge_cso').run[:rows_upserted]).to eq(2)
    allow(Time).to receive(:now).and_return(received + 1800)
    stub_request(:get, parent).to_return(status: 304)
    stub_request(:get, link).to_return(body: '%PDF-changed', headers: { 'ETag' => 'pdf-2' })

    expect(Muni::Water::Ingestor.new('cambridge_cso').run[:rows_upserted]).to eq(2)
    expect(storage.evidence.select_map(:status).uniq).to eq(['needs_review'])
    expect(storage.evidence.select_map(:fetched_at).uniq).to eq([received + 1800])
    expect(storage.db[:water_responses].where(url: parent).first[:retrieved_at]).to eq(received)
  end

  it 'keeps the effective receipt unchanged when both contributing responses return 304' do
    parent = Muni::Water::Catalog::CAMBRIDGE
    storage = Muni::Water::Storage
    received = Time.utc(2026, 10, 16, 12)
    allow(Time).to receive(:now).and_return(received)
    stub_request(:get, parent).to_return(body: notice, headers: { 'ETag' => 'table-1' })
    stub_request(:get, link).to_return(body: pdf, headers: { 'ETag' => 'pdf-1' })
    expect(Muni::Water::Ingestor.new('cambridge_cso').run[:rows_upserted]).to eq(2)
    allow(Time).to receive(:now).and_return(received + 900)
    stub_request(:get, parent).to_return(status: 304)
    stub_request(:get, link).to_return(status: 304)

    expect(Muni::Water::Ingestor.new('cambridge_cso').run[:rows_upserted]).to eq(0)
    expect(storage.evidence.select_map(:fetched_at).uniq).to eq([received])
    expect(storage.db[:water_revisions].count).to eq(2)
  end

  it 'rejects an older staged correction for both table records and retained synthetic omissions' do
    parent = Muni::Water::Catalog::CAMBRIDGE
    storage = Muni::Water::Storage
    received = Time.utc(2026, 10, 16, 12)
    allow(Time).to receive(:now).and_return(received + 900)
    stub_request(:get, parent).to_return(body: notice)
    stub_request(:get, link).to_return(body: pdf)
    expect(Muni::Water::Ingestor.new('cambridge_cso').run[:rows_upserted]).to eq(2)
    { parent => notice, link => '%PDF-older-unverified' }.each do |url, body|
      storage.db[:water_pending_pages].insert(
        source_slug: 'water/charles/cambridge_cso', url: url, retrieved_at: received, snapshot_at: received,
        headers: '{}', body: Sequel.blob(Zlib.gzip(body))
      )
    end
    allow(Time).to receive(:now).and_return(received + 1800)

    expect(Muni::Water::Ingestor.new('cambridge_cso').run[:rows_upserted]).to eq(0)
    expect(storage.evidence.order(:location_id).select_map(:status)).to eq(%w[retracted published])
    expect(storage.evidence.select_map(:fetched_at).uniq).to eq([received + 900])
    expect(storage.db[:water_revisions].count).to eq(2)
    expect(a_request(:get, link)).to have_been_made.once
  end
end
