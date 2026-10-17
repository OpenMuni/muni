require 'spec_helper'

RSpec.describe Muni::Water, '.processing_enabled?' do
  let(:water_beat) do
    Class.new(Muni::Water::Collector) do
      def self.slug = 'water/charles/epa_buoy'
    end
  end
  let(:municipal_beat) do
    Class.new(Muni::Beat) do
      def self.slug = 'cambridge/processing_pause_spec'
      def self.every_seconds = 60
      def self.runs = @runs ||= 0
      def self.record_run = @runs = runs + 1
      def run! = self.class.record_run
    end
  end

  around do |example|
    keys = %w[MUNI_WATER_ENABLED MUNI_WATER_PROCESSING_ENABLED MUNI_WATER_PRESENTATION_ENABLED]
    previous = keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    ENV.update('MUNI_WATER_ENABLED' => '1', 'MUNI_WATER_PROCESSING_ENABLED' => '0',
               'MUNI_WATER_PRESENTATION_ENABLED' => '0')
    example.run
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  before { Muni::Store.ensure_tables! }

  it 'defaults to processing enabled when no pause is configured' do
    ENV.delete('MUNI_WATER_PROCESSING_ENABLED')
    expect(described_class.processing_enabled?).to be(true)
  end

  it 'skips collection before acquiring a lease or starting an ingestion run' do
    allow(Muni::Water::ScheduleStore).to receive(:acquire).and_call_original
    allow(Muni::Water::Ingestor).to receive(:new).and_call_original
    expect(water_beat.new.run!).to include(skipped: true, error: nil)
    expect(Muni::Water::ScheduleStore).not_to have_received(:acquire)
    expect(Muni::Water::Ingestor).not_to have_received(:new)
    expect(Muni::Water::Storage.db[:water_runs].count).to eq(0)
  end

  it 'keeps municipal jobs running while skipping water calculations and collections' do
    allow(Muni::Water::DailySummaries).to receive(:new).and_call_original
    allow(Muni::Water::Calculations).to receive(:new).and_call_original
    scheduler = Muni::Scheduler.new(beats: [water_beat, municipal_beat])
    expect(scheduler.tick_once).to eq(2)
    expect(municipal_beat.runs).to eq(1)
    expect(Muni::Water::DailySummaries).not_to have_received(:new)
    expect(Muni::Water::Calculations).not_to have_received(:new)
    expect(Muni::Water::Storage.db[:water_runs].count).to eq(0)
  end

  it 'keeps water enabled and coverage readable while presentation is under maintenance' do
    expect(described_class.enabled?).to be(true)
    expect(described_class.presentation_enabled?).to be(false)
    expect(Muni::Water::Query.new.coverage.count { |row| row[:source_slug] }).to eq(8)
  end

  it 'allows an explicit importer to publish and calculate during the scheduled pause' do
    client = instance_double(Muni::Water::Client, responses: [], validators: {})
    adapter = instance_double(Muni::Water::Adapters::Base, collect: [], locations: [], metadata: {},
                               checkpoint: {}, client: client)
    result = Muni::Water::Ingestor.new('epa_buoy').run(adapter: adapter)
    expect(result).to include(error: nil, calculation_status: 'complete')
    expect(Muni::Water::Storage.db[:water_runs].first[:status]).to eq('complete')
  end
end
