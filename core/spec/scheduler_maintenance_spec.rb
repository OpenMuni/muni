require 'spec_helper'

RSpec.describe Muni::Scheduler, '#tick_once' do
  let(:clock) { { now: Time.utc(2026, 10, 17, 12), calls: [] } }
  let(:logger) { instance_double(Logger, info: nil, error: nil) }
  let(:scheduler) { described_class.new(beats: [municipal, water], clock: -> { clock[:now] }, logger: logger) }
  let(:municipal) do
    observed = calls
    Class.new(Muni::Beat) do
      define_singleton_method(:slug) { 'cambridge/maintenance_spec' }
      define_singleton_method(:every_seconds) { 60 }
      define_method(:run!) { observed << :municipal }
    end
  end
  let(:water) do
    observed = calls
    Class.new(Muni::Water::Collector) do
      define_singleton_method(:slug) { 'water/charles/epa_buoy' }
      define_method(:run!) { observed << :water }
    end
  end

  def calls = clock[:calls]

  around do |example|
    keys = %w[MUNI_BACKUP_PATH MUNI_BEAT_STAGGER_SECONDS]
    previous = keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    Dir.mktmpdir('scheduler-maintenance') do |directory|
      ENV['MUNI_BACKUP_PATH'] = directory
      ENV['MUNI_BEAT_STAGGER_SECONDS'] = '0'
      example.run
    end
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  before do
    Muni::Store.ensure_tables!
    allow(Muni::Store).to receive(:maintenance_enabled?).and_return(true)
    allow(Time).to receive(:now) { clock[:now] }
    allow(Muni::Store).to receive(:perform_maintenance!).and_call_original
    allow(Muni::Store).to receive(:backup!).and_call_original
    allow(FileUtils).to receive(:mkdir_p).and_call_original
    allow(FileUtils).to receive(:mkdir_p).with(ENV.fetch('MUNI_BACKUP_PATH')).and_raise(IOError, 'capture unavailable')
  end

  it 'continues due jobs, preserves failed-backup status and defers another maintenance attempt' do
    expect(scheduler.tick_once).to eq(2)
    expect(calls).to contain_exactly(:municipal, :water)
    expect(Muni::Status::Backup.snapshot(now: clock[:now])).to include(status: 'failed', failure_state: 'failed')
    expect(logger).to have_received(:error).with(include('capture unavailable', 'retry after 2026-10-17T12:15:00Z'))

    clock[:now] += 899
    expect(scheduler.tick_once).to eq(2)
    expect(calls.count(:municipal)).to eq(2)
    expect(calls.count(:water)).to eq(2)
    expect(Muni::Store).to have_received(:perform_maintenance!).once
  end

  it 'retries at fifteen minutes and clears backoff after a successful capture' do
    scheduler.tick_once
    allow(FileUtils).to receive(:mkdir_p).with(ENV.fetch('MUNI_BACKUP_PATH')).and_call_original
    clock[:now] += 900
    scheduler.tick_once
    expect(Muni::Store).to have_received(:perform_maintenance!).twice
    expect(Muni::Status::Backup.snapshot(now: clock[:now])).to include(status: 'current', failure_state: 'recovered')

    clock[:now] += 1
    scheduler.tick_once
    expect(Muni::Store).to have_received(:perform_maintenance!).exactly(3).times
    expect(Muni::Store).to have_received(:backup!).twice
  end
end
