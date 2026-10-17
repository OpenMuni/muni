require 'spec_helper'

RSpec.describe Muni::Water::RunTiming do
  let(:clock) { { now: Time.utc(2026, 10, 16, 14) } }
  let(:db) { Muni::Water::Storage.db }
  let(:slug) { 'water/charles/epa_buoy' }
  let(:collector) do
    Class.new(Muni::Water::Collector) do
      def self.slug = 'water/charles/epa_buoy'
    end
  end
  let(:adapter) do
    client = instance_double(Muni::Water::Client, responses: [], validators: {})
    instance_double(Muni::Water::Adapters::Base, collect: [], locations: [], metadata: { publisher_note: 'retained' },
                    checkpoint: {}, client: client)
  end

  before do
    Muni::Store.ensure_tables!
    allow(Time).to receive(:now) { clock[:now] }
    allow(Muni::Water).to receive_messages(enabled?: true, processing_enabled?: true)
    allow(Muni::Water::Adapters).to receive(:build).and_return(adapter)
    allow(Muni::Store).to receive(:perform_maintenance!)
  end

  def history(at: clock[:now])
    Muni::Water::ScheduleHistory.new(slug, now: at).call
  end

  def latest_timing
    JSON.parse(db[:water_runs].order(:id).last[:metadata]).fetch('scheduling')
  end

  it 'retains immutable due/start facts and the linked next decision through successful publication' do
    scheduler = Muni::Scheduler.new(beats: [collector], clock: -> { clock[:now] })
    scheduler.tick_once
    first = db[:water_runs].first[:id]
    clock[:now] += 620
    scheduler.tick_once
    expect(latest_timing).to include('invocation' => 'scheduler', 'trigger' => 'calendar',
                                     'due_at' => '2026-10-16T14:10:00.000000Z',
                                     'started_at' => '2026-10-16T14:10:20.000000Z',
                                     'expected_from_run_id' => first, 'delay_seconds' => 20,
                                     'next_due_at' => '2026-10-16T14:40:00.000000Z')
    expect(latest_timing.dig('policy', 'calendar')).to eq('minutes' => [10, 40])
    expect(JSON.parse(db[:water_runs].order(:id).last[:metadata])['publisher_note']).to eq('retained')
    expect(db[:water_batches].order(:started_at).last[:run_id]).to eq(db[:water_runs].max(:id))
    expect(history).to include(eligible_starts: 1, p95_start_delay_seconds: 20, failed_starts: 0)
  end

  it 'counts failed scheduled starts and retains retry decisions even when adapter construction fails' do
    scheduler = Muni::Scheduler.new(beats: [collector], clock: -> { clock[:now] })
    scheduler.tick_once
    clock[:now] += 605
    allow(Muni::Water::Adapters).to receive(:build).and_raise(Muni::Helpers::Http::Error.new(503, 'unavailable'))
    scheduler.tick_once
    expect(db[:water_runs].order(:id).last[:status]).to eq('failed')
    expect(latest_timing).to include('trigger' => 'calendar', 'delay_seconds' => 5,
                                     'next_trigger' => 'retry', 'next_due_at' => '2026-10-16T14:25:05.000000Z')
    expect(history).to include(eligible_starts: 1, failed_starts: 1, p95_start_delay_seconds: 5)
    allow(Muni::Water::Adapters).to receive(:build).and_return(adapter)
    clock[:now] += 901
    scheduler.tick_once
    expect(latest_timing).to include('trigger' => 'retry', 'delay_seconds' => 1)
    expect(history).to include(eligible_starts: 2, p95_start_delay_seconds: 5)
    expect(history.dig(:timing_groups, :retry)).to include(starts: 1, p95_start_delay_seconds: 1)
    expect(history.dig(:timing_groups, :failed)).to include(starts: 1, p95_start_delay_seconds: 5)
  end

  it 'keeps manual and explicit reconciliation runs separate from scheduled timing' do
    Thread.current[:muni_scheduler_entry] = { source_slug: 'water/charles/wqp', due_at: clock[:now] - 100 }
    Muni::Water::Ingestor.new('epa_buoy').run(adapter: adapter)
    expect(latest_timing).to include('invocation' => 'manual', 'trigger' => 'manual', 'delay_seconds' => nil)
    Muni::Water::Ingestor.new('epa_buoy').run(reconcile: true)
    expect(latest_timing).to include('trigger' => 'reconcile', 'work_kind' => 'reconciliation')
    collector.new.run!
    expect(latest_timing).to include('invocation' => 'manual', 'trigger' => 'manual', 'due_at' => nil)
    expect(history).to include(eligible_starts: 0, excluded_runs: 3, p95_start_delay_seconds: nil)
  ensure
    Thread.current[:muni_scheduler_entry] = nil
  end

  it 'identifies bounded USGS history separately from routine publisher checks' do
    source = 'water/charles/usgs'
    checkpoint = { 'history_cursor' => '2026-01-01', 'routine_due_at' => (clock[:now] + 3600).iso8601 }
    Muni::Water::Storage.save_checkpoint(source, checkpoint)
    result = Muni::Water::Ingestor.new('usgs').run(adapter: adapter)
    timing = JSON.parse(db[:water_runs].where(id: result[:run_id]).first[:metadata])['scheduling']
    expect(timing).to include('work_kind' => 'backfill', 'invocation' => 'manual')
    expect(Muni::Water::ScheduleHistory.new(source,
                                            now: clock[:now]).call).to include(eligible_starts: 0, excluded_runs: 1)
  end

  it 'does not invent a start when a lease blocks collection and reports the outstanding due separately' do
    scheduler = Muni::Scheduler.new(beats: [collector], clock: -> { clock[:now] })
    scheduler.tick_once
    clock[:now] += 600
    token = Muni::Water::ScheduleStore.acquire(slug, now: clock[:now])
    clock[:now] += 61
    scheduler.tick_once
    expect(db[:water_runs].count).to eq(1)
    expect(history).to include(eligible_starts: 0, p95_start_delay_seconds: nil)
    expect(history[:expectations]).to include(eligible_due: 1, overdue_without_start: 1,
                                              oldest_overdue_at: '2026-10-16T14:10:00.000000Z')
    expect(Muni::Water::ScheduleStore.read(slug)[:lease_token]).to eq(token)
  end

  it 'cannot attach the next decision from an expired lease to an unrelated replacement run' do
    result = Muni::Water::Ingestor.new('epa_buoy').run(adapter: adapter)
    first = Muni::Water::ScheduleStore.acquire(slug, now: clock[:now])
    replacement = Muni::Water::ScheduleStore.acquire(slug, now: clock[:now] + 901)
    Muni::Water::ScheduleStore.complete(slug, first, next_run_at: clock[:now] + 1800, failure_count: 0,
                                                    run_id: result[:run_id], next_trigger: 'calendar')
    expect(latest_timing).not_to have_key('next_due_at')
    expect(Muni::Water::ScheduleStore.read(slug)[:lease_token]).to eq(replacement)
  end

  it 'leaves legacy history unmeasured instead of fabricating due times or a full observation window' do
    db[:water_runs].insert(source_slug: slug, started_at: clock[:now] - 90_000, status: 'complete')
    db[:water_runs].insert(source_slug: slug, started_at: clock[:now] - 100, status: 'failed')
    Muni::Water::Ingestor.new('epa_buoy').run(adapter: adapter)
    expect(history).to include(legacy_unmeasured_runs: 1, measured_runs: 1, covers_full_window: false,
                               eligible_starts: 0, recorded_since: clock[:now])
    expect(db[:water_runs].first[:metadata]).to be_nil
  end

  it 'keeps an outstanding deadline visible when an outage lasts longer than the reporting window' do
    Muni::Scheduler.new(beats: [collector], clock: -> { clock[:now] }).tick_once
    clock[:now] += 2 * 86_400
    expect(history).to include(eligible_starts: 0, p95_start_delay_seconds: nil, covers_full_window: true)
    expect(history[:expectations]).to include(eligible_due: 0, overdue_without_start: 1, overdue_before_window: 1,
                                              oldest_overdue_at: '2026-10-16T14:10:00.000000Z')
  end

  it 'does not reclassify a committed start after a derived calculation dispatcher fails' do
    calculations = instance_double(Muni::Water::Calculations)
    allow(Muni::Water::Calculations).to receive(:new).and_return(calculations)
    allow(calculations).to receive(:drain).and_raise('calculation unavailable')
    result = collector.new.run!
    expect(result).to include(error: nil, calculation_status: 'failed')
    expect(db[:water_runs].where(id: result[:run_id]).first[:status]).to eq('complete')
    expect(latest_timing).to include('invocation' => 'manual', 'next_trigger' => 'calendar')
  end

  it 'rolls back the schedule decision if its linked run history cannot be saved' do
    result = Muni::Water::Ingestor.new('epa_buoy').run(adapter: adapter)
    token = Muni::Water::ScheduleStore.acquire(slug, now: clock[:now])
    db.run("CREATE TRIGGER reject_timing BEFORE UPDATE ON water_runs BEGIN SELECT RAISE(ABORT, 'rejected'); END")
    expect do
      Muni::Water::ScheduleStore.complete(slug, token, next_run_at: clock[:now] + 600, failure_count: 0,
                                                      run_id: result[:run_id], next_trigger: 'calendar')
    end.to raise_error(Sequel::DatabaseError, /rejected/)
    expect(Muni::Water::ScheduleStore.read(slug)).to include(lease_token: token, next_run_at: nil)
    expect(latest_timing).not_to have_key('next_due_at')
  end

  it 'measures a routine USGS check against its hourly deadline when it interrupts backfill' do
    source = 'water/charles/usgs'
    checkpoint = { 'history_cursor' => '2026-01-01', 'routine_due_at' => (clock[:now] - 10).iso8601 }
    Muni::Water::Storage.save_checkpoint(source, checkpoint)
    scheduling = { invocation: 'scheduler', trigger: 'backfill', due_at: (clock[:now] - 5).iso8601 }
    result = Muni::Water::Ingestor.new('usgs').run(adapter: adapter, scheduling: scheduling)
    timing = JSON.parse(db[:water_runs].where(id: result[:run_id]).first[:metadata])['scheduling']
    expect(timing).to include('work_kind' => 'routine', 'trigger' => 'backfill', 'delay_seconds' => 5,
                              'due_at' => (clock[:now] - 5).iso8601, 'routine_delay_seconds' => 10)
    expect(Muni::Water::ScheduleHistory.new(source, now: clock[:now]).call)
      .to include(eligible_starts: 1, p95_start_delay_seconds: 10)
  end

  it 'reports nearest-rank p95 from all eligible starts, including failures, instead of the latest start' do
    (1..20).each do |delay|
      timing = { version: described_class::VERSION, invocation: 'scheduler', trigger: 'calendar',
                 work_kind: 'routine', delay_seconds: delay }
      db[:water_runs].insert(source_slug: slug, started_at: clock[:now] - delay,
                             status: delay == 19 ? 'failed' : 'complete',
                             metadata: Muni::Water.json(scheduling: timing))
    end
    expect(history).to include(eligible_starts: 20, p95_start_delay_seconds: 19,
                               max_start_delay_seconds: 20, failed_starts: 1)
    expect(history[:timing_groups]).to include(
      successful_calendar_or_resumed: { starts: 19, p95_start_delay_seconds: 20, max_start_delay_seconds: 20 },
      failed:                         { starts: 1, p95_start_delay_seconds: 19, max_start_delay_seconds: 19 }
    )
  end

  it 'uses the completed USGS window to distinguish resumed history from the wall-clock start plan' do
    source = 'water/charles/usgs'
    checkpoint = { 'history_cursor' => '2026-01-01', 'routine_due_at' => (clock[:now] - 10).iso8601 }
    Muni::Water::Storage.save_checkpoint(source, checkpoint)
    allow(adapter).to receive(:metadata).and_return(full_reconciliation: true)
    scheduling = { invocation: 'scheduler', trigger: 'backfill', due_at: (clock[:now] - 5).iso8601 }
    result = Muni::Water::Ingestor.new('usgs').run(adapter: adapter, scheduling: scheduling)
    timing = JSON.parse(db[:water_runs].where(id: result[:run_id]).first[:metadata])['scheduling']
    expect(timing).to include('work_kind' => 'backfill', 'planned_work_kind' => 'routine',
                              'work_kind_basis' => 'completed_adapter_window', 'trigger' => 'backfill',
                              'due_at' => (clock[:now] - 5).iso8601, 'delay_seconds' => 5)
    expect(Muni::Water::ScheduleHistory.new(source, now: clock[:now]).call)
      .to include(eligible_starts: 0, excluded_runs: 1, p95_start_delay_seconds: nil)
  end
end
