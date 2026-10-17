require 'spec_helper'

RSpec.describe Muni::Water::RecordProjection do
  let(:storage) { Muni::Water::Storage }
  let(:now) { Time.utc(2026, 10, 17) }

  before { Muni::Store.ensure_tables! }

  def reading(id, value)
    Muni::Water::Adapters::Base.new(id: 'epa_buoy', now: now).record(
      id: id, kind: 'sensor', location_id: 'epa-buoy', parameter: 'temperature', unit: '°C',
      method: 'sensor', segment: '2026', observed_at: now, value: value, raw: { value: value }
    )
  end

  def publish(*records)
    storage.db.transaction { Muni::Water::EvidenceWriter.new(now: now).call(records) }
  end

  it 'serves current and future cutoffs without reading archived revision bodies' do
    publish(reading('first', 10), reading('second', 20))
    cutoff = storage.db[:water_revisions].max(:id)
    storage.db.synchronize do |connection|
      connection.authorizer = lambda do |action, table, column, _database, _trigger|
        !(action == 20 && table == 'water_revisions' && column == 'record') # SQLite READ
      end
      storage.db.transaction do
        [cutoff, cutoff + 100].each do |boundary|
          expect(described_class.snapshot(boundary).order(:value).select_map(:value)).to eq([10, 20])
        end
      end
    ensure
      connection.authorizer = nil
    end
  end

  it 'keeps an older cutoff unchanged after a correction and a new observation are published' do
    publish(reading('first', 10), reading('second', 20))
    cutoff = storage.db[:water_revisions].max(:id)
    publish(reading('first', 99), reading('new', 30))
    storage.db.transaction do
      expect(described_class.snapshot(cutoff).order(:value).select_map(:value)).to eq([10, 20])
      current = storage.db[:water_revisions].max(:id)
      expect(described_class.snapshot(current).order(:value).select_map(:value)).to eq([20, 30, 99])
      expect(described_class.snapshot(0).count).to eq(0)
    end
  end

  it 'keeps the current projection stable when another connection commits after the cutoff check' do
    publish(reading('first', 10))
    database = storage.db
    writer = Sequel.sqlite(Muni::Config.db_path)
    database.transaction do
      snapshot = described_class.snapshot(database[:water_revisions].max(:id))
      allow(storage).to receive(:db).and_return(writer)
      publish(reading('first', 99))
      allow(storage).to receive(:db).and_return(database)
      expect(snapshot.select_map(:value)).to eq([10])
    end
    expect(database[:water_evidence].select_map(:value)).to eq([99])
  ensure
    writer&.disconnect
  end

  def page_records
    [reading('a', 10).merge(external_id: 'a', observed_at: now + 0.111111),
     reading('b', 20).merge(external_id: 'b', observed_at: now + 0.999999),
     reading('c', 30).merge(external_id: 'c', observed_at: nil, observed_date: '2026-10-17', time_precision: 'date'),
     reading('d', 40).merge(external_id: 'd', observed_at: now - 60)]
  end

  def page(cursor)
    Muni::Water::Query.new(now: now).records({ 'cursor' => cursor, 'limit' => '1' })
  end

  it 'paginates current rows with tied public timestamps and date-only rows without repeats or omissions' do
    publish(*page_records)
    cursor = 'start'
    ids = []
    loop do
      result = page(cursor)
      ids.concat(result[:records].map { |row| row['external_id'] })
      expect(result[:records].first).not_to have_key('cursor_date')
      cursor = result[:next_cursor]
      break unless cursor
    end
    expect(ids).to eq(%w[a b c d])
  end

  it 'accepts older cursor timestamp formats before and after a publication switches the page to history' do
    publish(*page_records)
    first = page('start')
    expect(first[:records].map { |row| row['external_id'] }).to eq(['a'])
    position = JSON.parse(Base64.urlsafe_decode64(first[:next_cursor]))
    [false, true].each do |corrected|
      publish(page_records[1].merge(value: 99, raw: { value: 99 })) if corrected
      [now.iso8601, now.to_s].each do |stamp|
        cursor = Base64.urlsafe_encode64(JSON.generate(position.merge('last_date' => stamp)))
        second = page(cursor)
        expect(second[:records].map { |row| row.values_at('external_id', 'value') }).to eq([['b', 20]])
        third = page(second[:next_cursor])
        expect(third[:records].map { |row| row['external_id'] }).to eq(['c'])
        date_position = JSON.parse(Base64.urlsafe_decode64(third[:next_cursor]))
        expect(date_position['last_date']).to eq('2026-10-17')
        expect(page(third[:next_cursor])[:records].map { |row| row['external_id'] }).to eq(['d'])
      end
    end
  end
end
