require 'spec_helper'

RSpec.describe Muni::Water::Ingestor do
  let(:now) { Time.utc(2026, 10, 16, 20) }
  let(:storage) { Muni::Water::Storage }
  let(:slug) { 'water/charles/epa_buoy' }

  before { Muni::Store.ensure_tables! }

  def reading(value: 10, fetched_at: now)
    Muni::Water::Adapters::Base.new(id: 'epa_buoy', now: now).record(
      id: 'stable-source-reading', kind: 'sensor', location_id: 'epa-buoy', parameter: 'temperature', unit: '°C',
      method: 'sensor', segment: '2026', observed_at: now, value: value, fetched_at: fetched_at, raw: { value: value }
    )
  end

  def ingest(records = [reading], at: now, responses: [], metadata: {}, checkpoint: {})
    client = instance_double(Muni::Water::Client, responses: responses, validators: {})
    adapter = instance_double(Muni::Water::Adapters::Base, collect: records, locations: [],
                              metadata: metadata, checkpoint: checkpoint, client: client)
    described_class.new('epa_buoy', now: at).run(adapter: adapter)
  end

  def observe_serialization_scope
    observed = { in_writer: false, cursor: false, dirty: false }
    allow(Muni::Store).to receive(:with_writer).and_wrap_original do |original, &block|
      original.call do
        observed[:in_writer] = true
        block.call
      ensure
        observed[:in_writer] = false
      end
    end
    allow(Muni::Water).to receive(:json).and_wrap_original do |original, value|
      cursor = value.is_a?(Hash) && value.key?('buoy_row_fingerprints')
      dirty = value.is_a?(Array) && value.first.is_a?(Hash) &&
              (value.first.key?('selector') || value.first.key?(:selector))
      if cursor || dirty
        expect(observed[:in_writer]).to be(false)
        observed[:cursor] ||= cursor
        observed[:dirty] ||= dirty
      end
      original.call(value)
    end
    observed
  end

  it 'retains a successful publication when a calculation fails and retries without recollecting' do
    summaries = instance_double(Muni::Water::DailySummaries)
    allow(Muni::Water::DailySummaries).to receive(:new).and_return(summaries)
    allow(summaries).to receive(:refresh).and_raise('Summary worker unavailable')

    result = ingest

    expect(result.values_at(:error, :rows_upserted, :calculation_status)).to eq([nil, 1, 'failed'])
    expect(storage.db[:water_runs].first[:status]).to eq('complete')
    expect(storage.db[:water_batches].first[:status]).to eq('calculation_failed')
    expect(storage.checkpoint(slug)['last_success_at']).to eq(now.iso8601)
    expect(storage.db[:water_calculation_jobs].first[:retry_at]).to eq(now + 30)
    allow(Muni::Water::DailySummaries).to receive(:new).and_call_original
    Muni::Water::Calculations.new(now: now + 31).drain(slug: slug)
    expect(storage.db[:water_batches].first[:status]).to eq('complete')
    expect(storage.db[:water_revisions].count).to eq(1)
    expect(storage.db[:water_runs].count).to eq(1)
  end

  it 'does not turn a committed collection into a failure when the calculation dispatcher crashes' do
    calculations = instance_double(Muni::Water::Calculations)
    allow(Muni::Water::Calculations).to receive(:new).and_return(calculations)
    allow(calculations).to receive(:drain).and_raise('Dispatcher unavailable')

    result = ingest

    expect(result.values_at(:error, :rows_upserted, :calculation_status)).to eq([nil, 1, 'failed'])
    expect(storage.evidence.count).to eq(1)
    expect(storage.db[:water_runs].first[:status]).to eq('complete')
    expect(storage.db[:water_calculation_jobs].first[:status]).to eq('failed')
  end

  it 'rejects an older resumed response that would overwrite a newer correction' do
    expect(ingest([reading(value: 11, fetched_at: now + 900)])[:rows_upserted]).to eq(1)

    result = ingest([reading(value: 10, fetched_at: now)], at: now + 1800)

    expect(result.values_at(:error, :rows_upserted)).to eq([nil, 0])
    expect(storage.evidence.first.values_at(:value, :fetched_at)).to eq([11, now + 900])
    expect(storage.db[:water_revisions].count).to eq(1)
  end

  it 'retains exact response bytes, immutable manifests and actual processing phase times' do
    bytes = "%PDF-1.7\xFF\x00\x80".b
    response = { url: 'https://example.gov/correction.pdf', body: bytes, retrieved_at: now - 3600,
                 headers: { 'etag' => 'document-1', 'content-type' => 'application/pdf' } }
    started = Time.now.utc
    result = ingest(responses: [response])
    ended = Time.now.utc
    batch = storage.db[:water_batches].where(id: result[:batch_id]).first
    phases = batch.values_at(:started_at, :retrieved_at, :normalized_at, :published_at, :calculated_at)
    expect(phases).to eq(phases.sort)
    expect(phases.all? { |time| time.between?(started, ended) }).to be(true)
    manifest = JSON.parse(batch[:manifest]).first
    expect(manifest).to include('digest' => Digest::SHA256.hexdigest(bytes), 'headers' => response[:headers],
                                'retrieved_at' => response[:retrieved_at].iso8601(6))
    retained = storage.db[:water_responses].first
    expect(Zlib.gunzip(retained[:body])).to eq(bytes)
    expect(retained[:retrieved_at]).to eq(response[:retrieved_at])
    ingest([], at: now + 3600)
    expect(storage.db[:water_batches].where(id: batch[:id]).first[:manifest]).to eq(batch[:manifest])
  end

  it 'keeps supporting PDFs beyond generic response retention without renewing their receipt timestamp' do
    received = now - (60 * 86_400)
    headers = { 'content-type' => 'application/pdf' }
    responses = [{ url: 'https://example.gov/correction.pdf', body: '%PDF-original',
                   retrieved_at: received, headers: headers },
                 { url: 'https://example.gov/table', body: '<table/>', retrieved_at: received, headers: {} }]
    ingest(responses: responses)
    expect(storage.db[:water_responses].select_map(:url)).to eq(['https://example.gov/correction.pdf'])
    ingest([], at: now + 3600, responses: [responses.first.merge(retrieved_at: now)])
    expect(storage.db[:water_responses].count).to eq(1)
    expect(storage.db[:water_responses].first[:retrieved_at]).to eq(received)
  end

  it 'records an unchanged successful check without changing the original evidence retrieval time' do
    ingest
    before = storage.evidence.first
    metadata = { 'unchanged_source' => true, 'publisher_note' => 'Archive unchanged.' }
    ingest([reading(fetched_at: now + 900)], at: now + 900, metadata: metadata)
    expect(storage.evidence.first).to eq(before)
    expect(storage.db[:water_revisions].count).to eq(1)
    expect(storage.checkpoint(slug)['last_success_at']).to eq((now + 900).iso8601)
    expect(JSON.parse(storage.db[:water_runs].order(:id).last[:metadata]))
      .to include('unchanged_source' => true, 'publisher_note' => 'Archive unchanged.')
  end

  it 'serializes the source cursor and dirty days before taking the shared writer lock' do
    observed = observe_serialization_scope
    checkpoint = { 'buoy_row_fingerprints' => 1000.times.to_h { |index| [index.to_s, 'source-fingerprint'] } }
    result = ingest(checkpoint: checkpoint)
    expect(result[:error]).to be_nil
    expect(observed.values_at(:cursor, :dirty)).to eq([true, true])
    job = JSON.parse(storage.db[:water_calculation_jobs].first[:payload])
    expect(job['dirty']).not_to be_empty
    expect(job['revision_range']).to eq([1, 1])
    expect(storage.checkpoint(slug)['buoy_row_fingerprints']).to eq(checkpoint['buoy_row_fingerprints'])
  end

  it 'rolls back evidence, revision, and calculation publication when the prepared checkpoint cannot commit' do
    previous = { 'cursor' => 'before', 'last_success_at' => (now - 900).iso8601 }
    storage.save_checkpoint(slug, previous)
    storage.db.run(<<~SQL)
      CREATE TRIGGER reject_water_checkpoint BEFORE UPDATE ON water_checkpoints
      BEGIN SELECT RAISE(ABORT, 'checkpoint rejected'); END
    SQL

    result = ingest(checkpoint: { 'cursor' => 'after' })

    expect(result[:error].message).to include('checkpoint rejected')
    expect(storage.checkpoint(slug)).to eq(previous)
    expect(storage.evidence.count).to eq(0)
    expect(storage.db[:water_revisions].count).to eq(0)
    expect(storage.db[:water_calculation_jobs].count).to eq(0)
    storage.db.run('DROP TRIGGER reject_water_checkpoint')
    expect(ingest(checkpoint: { 'cursor' => 'after' })[:error]).to be_nil
    expect(storage.checkpoint(slug)['cursor']).to eq('after')
  end
end
