require 'spec_helper'

RSpec.describe Muni::Water::Schedule do
  before do
    Muni::Store.ensure_tables!
    Muni::Store.with_writer { Muni::Water::ScheduleStore.ensure_table! }
  end

  def schedule(id)
    described_class.new("water/charles/#{id}", Muni::Water::Catalog.definitions.fetch(id))
  end

  it 'aligns frequent publishers to UTC slots without drifting from completion time' do
    now = Time.utc(2026, 10, 16, 21, 11)
    expect(schedule('epa_buoy').next_after(now)).to eq(Time.utc(2026, 10, 16, 21, 40))
    expect(schedule('usgs').next_after(now)).to eq(Time.utc(2026, 10, 16, 21, 50))
    expect(schedule('crwa_predictions').next_after(now)).to eq(Time.utc(2026, 10, 16, 22, 10))
    expect(schedule('cambridge_cso').next_after(now)).to eq(Time.utc(2026, 10, 16, 21, 15))
  end

  it 'keeps weekly WQP checks at 04:00 Eastern across both daylight-saving changes' do
    expect(schedule('wqp').next_after(Time.utc(2026, 3, 6, 9))).to eq(Time.utc(2026, 3, 13, 8))
    expect(schedule('wqp').next_after(Time.utc(2026, 10, 30, 8))).to eq(Time.utc(2026, 11, 6, 9))
  end

  it 'keeps daily archive checks at 05:00 Eastern across both daylight-saving changes' do
    expect(schedule('crwa_laboratory').next_after(Time.utc(2026, 3, 7, 10))).to eq(Time.utc(2026, 3, 8, 9))
    expect(schedule('crwa_laboratory').next_after(Time.utc(2026, 10, 31, 9))).to eq(Time.utc(2026, 11, 1, 10))
  end

  it 'persists retry timing while retaining the normal calendar anchor after recovery' do
    now = Time.utc(2026, 10, 16, 8)
    slug = 'water/charles/wqp'
    token = Muni::Water::ScheduleStore.acquire(slug, now: now)
    failure = Muni::Helpers::Http::Error.new(503, 'unavailable')
    timing = schedule('wqp').finish(now, failure)
    Muni::Water::ScheduleStore.complete(slug, token, **timing)

    expect(schedule('wqp').initial(now + 60)).to eq(now + 900)
    expect(schedule('wqp').finish(now + 900, nil)).to eq(next_run_at: Time.utc(2026, 10, 23, 8), failure_count: 0)
  end

  it 'honors Retry-After even when it postpones a normal publisher slot' do
    now = Time.utc(2026, 10, 16, 21)
    failure = Muni::Helpers::Http::Error.new(429, 'slow down', headers: { 'retry-after' => '3600' }, now: now)
    expect(schedule('epa_buoy').finish(now, failure)[:next_run_at]).to eq(now + 3600)
    permanent = Muni::Helpers::Http::Error.new(404, 'missing')
    expect(schedule('wqp').finish(now, permanent)[:next_run_at]).to eq(Time.utc(2026, 10, 23, 8))
  end

  it 'prevents overlapping leases and rejects a stale owner after crash recovery' do
    now = Time.utc(2026, 10, 16)
    store = Muni::Water::ScheduleStore
    slug = 'water/charles/epa_buoy'
    first = store.acquire(slug, now: now)
    expect(store.acquire(slug, now: now + 1)).to be_nil
    replacement = store.acquire(slug, now: now + 901)
    expect(replacement).not_to eq(first)
    store.complete(slug, first, next_run_at: now + 1800, failure_count: 0)
    expect(store.read(slug)[:lease_token]).to eq(replacement)
  end

  it 'preserves explicit interval overrides' do
    key = 'MUNI_WATER_EPA_BUOY_INTERVAL'
    old = ENV.fetch(key, nil)
    ENV[key] = '120'
    now = Time.utc(2026, 10, 16, 21, 11)
    expect(schedule('epa_buoy').next_after(now)).to eq(now + 120)
  ensure
    old ? ENV[key] = old : ENV.delete(key)
  end

  it 'does not replace an expired lease while the original source publication is still running' do
    now = Time.utc(2026, 10, 16)
    store = Muni::Water::ScheduleStore
    slug = 'water/charles/epa_buoy'
    token = store.acquire(slug, now: now)
    path = "#{Muni::Config.db_path}.water-#{Muni::Water.hash(slug)[0, 16]}.lock"
    File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      expect(store.acquire(slug, now: now + 901)).to be_nil
      expect(store.read(slug)).to include(lease_token: token, lease_expires_at: now + 931, failure_count: 0)
    end
    store.complete(slug, token, next_run_at: now + 1800, failure_count: 0)
    expect(store.read(slug)).to include(lease_token: nil, next_run_at: now + 1800)
  end

  it 'records due and start times without losing the normal deadline when a check starts late' do
    now = Time.utc(2026, 10, 16)
    store = Muni::Water::ScheduleStore
    slug = 'water/charles/epa_buoy'
    token = store.acquire(slug, now: now)
    store.complete(slug, token, next_run_at: now + 1800, failure_count: 0)
    store.acquire(slug, now: now + 1815)
    expect(store.read(slug)).to include(last_due_at: now + 1800, last_started_at: now + 1815)
  end

  it 'defers a scheduled check without logging failure while a manual collector owns the source' do
    now = Time.utc(2026, 10, 16)
    slug = 'water/charles/epa_buoy'
    allow(Time).to receive(:now).and_return(now)
    allow(Muni::Water).to receive(:enabled?).and_return(true)
    allow(Muni::Water::Collector).to receive(:slug).and_return(slug)
    path = "#{Muni::Config.db_path}.water-#{Muni::Water.hash(slug)[0, 16]}.lock"
    File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      expect(Muni::Water::Collector.new.run!).to include(error: nil, skipped: true, next_run_at: now + 30)
      expect(Muni::Water::Storage.db[:water_runs].count).to eq(0)
      expect(Muni::Water::ScheduleStore.read(slug)[:failure_count]).to eq(0)
    end
  end

  it 'adds schedule timing fields without changing an existing persisted retry' do
    db = Muni::Water::Storage.db
    db.drop_table(:water_schedule_state)
    db.create_table(:water_schedule_state) do
      String :source_slug, primary_key: true
      DateTime :next_run_at
      Integer :failure_count
      String :lease_token
      DateTime :lease_expires_at
    end
    now = Time.utc(2026, 10, 16)
    db[:water_schedule_state].insert(source_slug: 'water/charles/wqp', next_run_at: now, failure_count: 2)
    Muni::Store.with_writer { Muni::Water::ScheduleStore.ensure_table! }
    expect(db[:water_schedule_state].first).to include(next_run_at: now, failure_count: 2,
                                                       last_due_at: nil, last_started_at: nil)
  end
end
