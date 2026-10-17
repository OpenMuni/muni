require 'spec_helper'

RSpec.describe Muni::Store do
  before { described_class.ensure_tables! }

  def build(extra = {})
    Muni::Records::ServiceRequest.new(
      external_id:  "sr/#{extra[:n] || 1}",
      hall:         extra[:hall] || 'cambridge',
      case_type:    extra[:case_type] || 'Pothole',
      status:       extra[:status] || 'Open',
      department:   'DPW',
      neighborhood: 'Cambridgeport',
      description:  'A service request',
      location:     [-71.10, 42.36],
      opened_at:    extra[:opened_at] || Time.now.utc,
      updated_at:   extra[:updated_at],
      closed_at:    extra[:closed_at],
      source_url:   'https://example.com'
    )
  end

  def build_digest(source_slug, external_id, attrs = {})
    now = attrs[:published_at] || attrs[:event_start_at] || Time.utc(2026, 6, 18, 12)
    Muni::Records::DigestItem.new(
      external_id: external_id,
      hall:        'cambridge',
      source_slug: source_slug,
      source_name: source_slug.split('/').last.tr('_', ' '),
      source_type: attrs.fetch(:source_type, 'official_record'),
      item_type:   attrs.fetch(:item_type, 'announcement'),
      title:       attrs.fetch(:title, external_id),
      fetched_at:  now,
      **attrs
    )
  end

  it 'upserts and counts' do
    described_class.upsert(build(n: 1))
    described_class.upsert(build(n: 1, status: 'Closed')) # same PK, must overwrite
    described_class.upsert(build(n: 2))

    expect(described_class.count(Muni::Records::ServiceRequest)).to eq(2)
    fetched = described_class.find(Muni::Records::ServiceRequest, 'sr/1')
    expect(fetched.status).to eq('Closed')
  end

  it 'allows the same external ID in different Halls and finds it with Hall scope' do
    described_class.upsert(build(n: 'shared', hall: 'cambridge', status: 'Open'))
    described_class.upsert(build(n: 'shared', hall: 'boston', status: 'Closed'))

    expect(described_class.count(Muni::Records::ServiceRequest)).to eq(2)
    expect(described_class.find(Muni::Records::ServiceRequest, 'sr/shared', hall: 'cambridge').status).to eq('Open')
    expect(described_class.find(Muni::Records::ServiceRequest, 'sr/shared', hall: 'boston').status).to eq('Closed')
  end

  it 'does not overwrite newer timestamped records with stale updates' do
    described_class.upsert(
      build(n: 'fresh', status: 'Closed', updated_at: Time.utc(2026, 6, 24, 20, 0, 0))
    )
    described_class.upsert(
      build(n: 'fresh', status: 'Open', updated_at: Time.utc(2026, 6, 12, 5, 0, 0))
    )

    fetched = described_class.find(Muni::Records::ServiceRequest, 'sr/fresh')
    expect(fetched.status).to eq('Closed')
    expect(fetched.updated_at).to eq(Time.utc(2026, 6, 24, 20, 0, 0))
  end

  it 'filters queries by where + since + limit' do
    described_class.upsert(build(n: 'a', hall: 'cambridge', opened_at: Time.utc(2026, 5, 1)))
    described_class.upsert(build(n: 'b', hall: 'cambridge', opened_at: Time.utc(2026, 5, 5)))
    described_class.upsert(build(n: 'c', hall: 'watertown', opened_at: Time.utc(2026, 5, 10)))

    rows = described_class.query(Muni::Records::ServiceRequest, since: Time.utc(2026, 5, 4))
    expect(rows.map { |r| r[:external_id] }.sort).to eq(%w[sr/b sr/c])

    rows = described_class.query(Muni::Records::ServiceRequest, hall: 'cambridge')
    expect(rows.map { |r| r[:external_id] }).to match_array(%w[sr/b sr/a])

    rows = described_class.query(Muni::Records::ServiceRequest, hall: 'cambridge', limit: 1)
    expect(rows.size).to eq(1)
  end

  it 'filters queries by a requested timestamp column' do
    described_class.upsert(
      build(n: 'opened-old', opened_at: Time.utc(2026, 5, 1), closed_at: Time.utc(2026, 5, 10))
    )
    described_class.upsert(
      build(n: 'closed-recent', opened_at: Time.utc(2026, 5, 1), closed_at: Time.utc(2026, 5, 20))
    )
    described_class.upsert(build(n: 'opened-recent', opened_at: Time.utc(2026, 5, 20)))

    rows = described_class.query(
      Muni::Records::ServiceRequest,
      since:       Time.utc(2026, 5, 15),
      since_field: :closed_at
    )

    expect(rows.map { |r| r[:external_id] }).to eq(['sr/closed-recent'])
  end

  it 'exposes public time and distinct value helpers for read adapters' do
    described_class.upsert(build(n: 'a', status: 'Open', opened_at: Time.utc(2026, 5, 1)))
    described_class.upsert(build(n: 'b', status: 'Closed', opened_at: Time.utc(2026, 5, 5)))
    described_class.upsert(build(n: 'c', hall: 'somerville', status: 'Ignored', opened_at: Time.utc(2026, 5, 6)))

    expect(described_class.time_column(Muni::Records::ServiceRequest)).to eq(:opened_at)
    expect(
      described_class.distinct_values(
        Muni::Records::ServiceRequest,
        :status,
        hall:  'cambridge',
        since: Time.utc(2026, 5, 2)
      )
    ).to eq(['Closed'])
    expect(described_class.latest_time(Muni::Records::ServiceRequest, hall: 'cambridge')).to eq(Time.utc(2026, 5, 5))
    expect(described_class.find(Muni::Records::ServiceRequest, 'sr/b').opened_at).to eq(Time.utc(2026, 5, 5))
  end

  it 'counts rows per source slug' do
    Muni.boot!
    described_class.upsert(build(n: 1))
    counts = described_class.counts_by_source(hall: 'cambridge')
    expect(counts['cambridge/service_requests']).to eq(1)
    expect(counts.keys).to all(start_with('cambridge/'))
  end

  it 'does not expose another Hall source names in Hall-scoped counts' do
    Muni.boot!
    described_class.upsert(build(n: 1, hall: 'boston'))

    counts = described_class.counts_by_source(hall: 'boston')

    expect(counts['boston/service_requests']).to eq(1)
    expect(counts.keys).to all(start_with('boston/'))
    expect(counts.keys).not_to include('cambridge/service_requests')
  end

  it 'scopes shared record tables by source slug when counting sources' do
    Muni.boot!
    now = Time.utc(2026, 6, 18, 12)
    described_class.upsert(build_digest('cambridge/city_news', 'news/counts', published_at: now))
    described_class.upsert(
      build_digest(
        'cambridge/city_calendar',
        'calendar/counts',
        source_type:    'event_listing',
        item_type:      'event',
        event_start_at: now
      )
    )

    counts = described_class.counts_by_source(hall: 'cambridge')

    expect(counts['cambridge/city_news']).to eq(1)
    expect(counts['cambridge/city_calendar']).to eq(1)
    expect(counts['cambridge/construction_highlights']).to eq(0)
  end

  it 'reports orphan tables without pruning them' do
    described_class.db.create_table(:housing_violations) do
      primary_key :id
    end
    described_class.db[:housing_violations].insert

    orphan = described_class.orphan_tables.find { |table| table[:table] == 'housing_violations' }

    expect(orphan).to include(rows: 1, status: 'orphaned', action: 'review_export_before_prune')
    expect(described_class.db.table_exists?(:housing_violations)).to be(true)
  end

  it 'deletes stale rows before a timestamp within an optional hall scope' do
    described_class.upsert(build(n: 'old', hall: 'cambridge', opened_at: Time.utc(2026, 5, 1)))
    described_class.upsert(build(n: 'new', hall: 'cambridge', opened_at: Time.utc(2026, 5, 10)))
    described_class.upsert(build(n: 'other-hall', hall: 'somerville', opened_at: Time.utc(2026, 5, 1)))

    deleted = described_class.delete_before(
      Muni::Records::ServiceRequest,
      :opened_at,
      Time.utc(2026, 5, 5),
      hall: 'cambridge'
    )

    expect(deleted).to eq(1)
    expect(described_class.find(Muni::Records::ServiceRequest, 'sr/old')).to be_nil
    expect(described_class.find(Muni::Records::ServiceRequest, 'sr/new')).not_to be_nil
    expect(described_class.find(Muni::Records::ServiceRequest, 'sr/other-hall')).not_to be_nil
  end

  it 'hydrates SQLite boolean values' do
    described_class.upsert(
      Muni::Records::Crash.new(
        external_id:          'crash/1',
        hall:                 'cambridge',
        crash_type:           'Auto / Bicycle',
        injury:               false,
        fatal:                true,
        location_description: 'Massachusetts Ave',
        location:             [-71.10, 42.36],
        occurred_at:          Time.utc(2026, 5, 1),
        source_url:           'https://example.com/crash/1'
      )
    )

    fetched = described_class.find(Muni::Records::Crash, 'crash/1')
    expect(fetched.injury).to be(false)
    expect(fetched.fatal).to be(true)
  end

  it 'tracks last_seen and beats_log' do
    t = Time.utc(2026, 5, 5, 12, 0, 0)
    described_class.bump_seen('cambridge/foo', t)
    expect(described_class.last_seen('cambridge/foo').to_i).to eq(t.to_i)

    described_class.log_beat_run(slug: 'cambridge/foo', started_at: t, ended_at: t + 5,
                                 rows_in: 3, rows_upserted: 3, error: nil)
    runs = described_class.recent_beat_runs
    expect(runs.first[:beat_slug]).to eq('cambridge/foo')
    expect(runs.first[:rows_upserted]).to eq(3)
    expect(described_class.latest_beat_run('cambridge/foo')[:ended_at].to_i).to eq((t + 5).to_i)
  end

  it 'upserts and reads cached analytics results' do
    generated_at = Time.utc(2026, 6, 16, 12, 0, 0)
    source_max_at = Time.utc(2026, 6, 15, 12, 0, 0)

    upsert_analytics_sample(12, generated_at, source_max_at)
    upsert_analytics_sample(13, generated_at, source_max_at)

    row = described_class.analytics_result(
      hall: 'cambridge', kind: 'service_request_resolution_model', key: 'default'
    )
    expect(row[:payload]['sample_size']).to eq(13)
    expect(row[:source_row_count]).to eq(13)
    expect(row[:source_max_at].to_i).to eq(source_max_at.to_i)
    expect(described_class.analytics_results(hall: 'cambridge').length).to eq(1)
  end

  def upsert_analytics_sample(sample_size, generated_at, source_max_at)
    described_class.upsert_analytics_result(
      hall:             'cambridge',
      kind:             'service_request_resolution_model',
      key:              'default',
      payload:          { status: 'ready', sample_size: sample_size },
      generated_at:     generated_at,
      source_row_count: sample_size,
      source_max_at:    source_max_at
    )
  end

  it 'adds newly declared record columns to existing tables' do
    klass = Class.new(Muni::Record) do
      def self.name = 'Muni::Records::SchemaEvolutionExample'

      schema do
        string :external_id, primary: true
        string :hall
      end
    end

    described_class.ensure_record_table!(klass)
    expect(described_class.db.schema(:schema_evolution_examples).map(&:first)).to include(:hall)

    klass.schema do
      string :external_id, primary: true
      string :hall
      time :collected_at
    end

    described_class.ensure_record_table!(klass)
    expect(described_class.db.schema(:schema_evolution_examples).map(&:first)).to include(:collected_at)
  ensure
    Muni::Registry.deregister_record('schema_evolution_examples')
  end
end
