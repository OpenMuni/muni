require 'spec_helper'

RSpec.describe Muni::Scheduler do
  before { Muni::Store.ensure_tables! }

  def beat(slug, &work)
    Class.new(Muni::Beat) do
      define_singleton_method(:slug) { slug }
      define_singleton_method(:every_seconds) { 3600 }
      define_method(:run!, &work)
    end
  end

  it 'runs another due collector between pages without recursively rerunning either collector' do
    now = Time.utc(2026, 10, 16)
    calls = []
    first = beat('water/a') do
      calls << [:first_page, Thread.current[:muni_scheduler_entry][:source_slug]]
      now += 31
      Thread.current[:muni_scheduler_yield].call
      calls << [:second_page, Thread.current[:muni_scheduler_entry][:source_slug]]
    end
    second = beat('water/b') do
      calls << [:routine_check, Thread.current[:muni_scheduler_entry][:source_slug]]
      Thread.current[:muni_scheduler_yield].call
    end
    scheduler = described_class.new(beats: [first, second], clock: -> { now })

    expect(scheduler.tick_once).to eq(2)
    expect(calls).to eq([[:first_page, 'water/a'], [:routine_check, 'water/b'], [:second_page, 'water/a']])
    expect(scheduler.tick_once).to eq(0)
    expect(Thread.current[:muni_scheduler_yield]).to be_nil
    expect(Thread.current[:muni_scheduler_entry]).to be_nil
  end
end
