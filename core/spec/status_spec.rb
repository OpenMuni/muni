require 'spec_helper'

RSpec.describe Muni::Status do
  before do
    Muni.boot!
    Muni::Hall.load_all!
    Muni::Store.ensure_tables!
  end

  def seed_all_sources(now: Time.now.utc, except: [])
    Muni::Registry.sources.keys.grep(%r{\Acambridge/}).each do |source_slug|
      next if except.include?(source_slug)

      seed_source(source_slug, now: now)
    end
    seed_all_beats(now: now)
  end

  def seed_all_beats(now: Time.now.utc)
    Muni::Registry.beats.keys.grep(%r{\Acambridge/}).each do |beat_slug|
      Muni::Store.log_beat_run(slug: beat_slug, started_at: now - 30, ended_at: now - 20, rows_in: 1, error: nil)
    end
  end

  def seed_source(source_slug, now: Time.now.utc)
    source = Muni::Registry.source(source_slug)
    schema = source.emits.schema_def
    attrs = {}
    attrs[schema.primary_key] = "status/#{source_slug}" if schema.primary_key
    attrs[:hall] = 'cambridge' if schema.column_names.include?(:hall)
    attrs[:source_slug] = source_slug if schema.column_names.include?(:source_slug)
    attrs[Muni::Store.time_column(source.emits)] = now - 60 if Muni::Store.time_column(source.emits)
    Muni::Store.upsert(source.emits.new(**attrs))
    Muni::Store.log_beat_run(slug: source_slug, started_at: now - 30, ended_at: now - 20, rows_in: 1, error: nil)
  end

  def with_status_env
    original = ENV.to_h
    ENV['MUNI_STATUS_LIVE_MAX_LAG_SECONDS'] = '3600'
    ENV['MUNI_STATUS_DIGEST_MAX_COLLECTION_LAG_SECONDS'] = '3600'
    ENV['MUNI_STATUS_SENSOR_MAX_COLLECTION_LAG_SECONDS'] = '3600'
    yield
  ensure
    ENV.replace(original)
  end

  it 'returns an operational public snapshot when Cambridge sources are fresh' do
    with_status_env do
      now = Time.now.utc
      seed_all_sources(now: now)

      snapshot = described_class.snapshot(hall: 'cambridge')

      expect(snapshot[:schema_version]).to eq(1)
      expect(snapshot[:backup]).to include(:status, :age_seconds, :last_success_at, :retention)
      expect(snapshot[:overall_status]).to eq('operational')
      expect(snapshot[:summary][:label]).to eq('Operational')
      expect(snapshot[:metrics][:total_sources]).to eq(Muni::Registry.sources.keys.grep(%r{\Acambridge/}).length)
      expect(snapshot[:sources].find { |source| source[:source] == 'cambridge/service_requests' }).to include(
        status:       'operational',
        source_mode:  'live',
        completeness: 'citywide_operational_feed'
      )
    end
  end

  it 'degrades when a live source has stale data' do
    with_status_env do
      now = Time.now.utc
      seed_all_sources(now: now, except: ['cambridge/service_requests'])
      seed_source('cambridge/service_requests', now: now - 86_400)

      snapshot = described_class.snapshot(hall: 'cambridge')
      service = snapshot[:sources].find { |source| source[:source] == 'cambridge/service_requests' }

      expect(snapshot[:overall_status]).to eq('degraded')
      expect(service).to include(status: 'degraded', reason: 'Live source data is stale.')
    end
  end

  it 'reports an outage when the critical 311 source has no records' do
    with_status_env do
      now = Time.now.utc
      seed_all_sources(now: now, except: ['cambridge/service_requests'])

      snapshot = described_class.snapshot(hall: 'cambridge')
      service = snapshot[:sources].find { |source| source[:source] == 'cambridge/service_requests' }

      expect(snapshot[:overall_status]).to eq('outage')
      expect(service).to include(status: 'outage', reason: 'Critical source has no collected rows.')
    end
  end

  it 'labels inventory and representative sensor sources without treating inventory age as live coverage' do
    with_status_env do
      now = Time.now.utc
      seed_all_sources(now: now)

      snapshot = described_class.snapshot(hall: 'cambridge')
      trees = snapshot[:sources].find { |source| source[:source] == 'cambridge/tree_inventory' }
      traffic = snapshot[:sources].find { |source| source[:source] == 'cambridge/traffic_volume_daily' }

      expect(trees).to include(
        status:       'operational',
        source_mode:  'inventory',
        completeness: 'official_inventory_snapshot',
        reason:       'Inventory snapshot is available.'
      )
      expect(traffic).to include(
        source_mode:  'representative_sensor',
        completeness: 'representative_sensor_network'
      )
    end
  end
end
