require 'spec_helper'

RSpec.describe Muni::Scheduler do
  let(:beat_class) do
    counts = []
    klass = Class.new(Muni::Beat) do
      define_singleton_method(:counts) { counts }
    end
    klass.beat('cambridge/test_beat', source: Class.new, every: '1s', mode: :full)
    klass.define_method(:run!) { klass.counts << Time.now }
    klass
  end

  after do
    Muni::Registry.deregister_beat('cambridge/test_beat')
  end

  it 'parses cadence strings to seconds' do
    expect(beat_class.every_seconds).to eq(1)
  end

  it 'runs entries whose next_run_at has passed' do
    now = Time.utc(2026, 5, 21, 0, 0, 0)
    clock = -> { now }
    sched = described_class.new(beats: [beat_class], clock: clock)

    expect(sched.tick_once).to eq(1)
    expect(beat_class.counts.size).to eq(1)

    expect(sched.tick_once).to eq(0) # already rescheduled, not yet due
    now += 2
    expect(sched.tick_once).to eq(1)
    expect(beat_class.counts.size).to eq(2)
  end

  it 'resumes beat cadence from the last persisted run' do
    Muni::Store.ensure_tables!
    now = Time.utc(2026, 5, 21, 12, 0, 0)
    Muni::Store.log_beat_run(
      slug:       beat_class.slug,
      started_at: now - 30,
      ended_at:   now,
      error:      nil
    )

    sched = described_class.new(beats: [beat_class], clock: -> { now })
    expect(sched.tick_once).to eq(0)

    now += 2
    expect(sched.tick_once).to eq(1)
    expect(beat_class.counts.size).to eq(1)
  end
end
