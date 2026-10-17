require 'spec_helper'

RSpec.describe Muni::Beat do
  before { Muni::Store.ensure_tables! }

  around do |example|
    original_overlap = ENV.fetch('MUNI_BEAT_OVERLAP_SECONDS', nil)
    example.run
  ensure
    if original_overlap.nil?
      ENV.delete('MUNI_BEAT_OVERLAP_SECONDS')
    else
      ENV['MUNI_BEAT_OVERLAP_SECONDS'] = original_overlap
    end
  end

  after do
    Muni::Registry.deregister_source('cambridge/overlap_test')
    Muni::Registry.deregister_beat('cambridge/overlap_test')
    Muni::Registry.deregister_source('cambridge/cursor_test')
    Muni::Registry.deregister_beat('cambridge/cursor_test')
  end

  it 'uses an overlap window when resuming incremental pulls' do
    source_class = Class.new(Muni::Source) do
      source :overlap_test,
             hall:     'cambridge',
             emits:    Muni::Records::ServiceRequest,
             base_url: 'https://example.com'

      class << self
        attr_accessor :seen_since
      end

      def pull(since: nil, **_)
        self.class.seen_since = since
        []
      end
    end

    beat_class = Class.new(described_class)
    beat_class.beat('cambridge/overlap_test', source: source_class, every: '1h')

    ENV['MUNI_BEAT_OVERLAP_SECONDS'] = '300'
    seen_at = Time.utc(2026, 6, 14, 12, 0, 0)
    Muni::Store.bump_seen('cambridge/overlap_test', seen_at)

    beat_class.new.run!

    expect(source_class.seen_since.to_i).to eq((seen_at - 300).to_i)
  end

  it 'passes configured limits into source pulls' do
    source_class = Class.new(Muni::Source) do
      source :overlap_test,
             hall:     'cambridge',
             emits:    Muni::Records::ServiceRequest,
             base_url: 'https://example.com'

      class << self
        attr_accessor :seen_limit
      end

      def pull(limit: nil, **_)
        self.class.seen_limit = limit
        []
      end
    end

    beat_class = Class.new(described_class)
    beat_class.beat('cambridge/overlap_test', source: source_class, every: '1h', limit: 17)

    beat_class.new.run!

    expect(source_class.seen_limit).to eq(17)
  end

  it 'prunes stale rows after successful full refresh beats opt in' do
    Muni::Store.upsert(stale_service_request)
    beat_class = Class.new(described_class)
    beat_class.beat('cambridge/overlap_test', source: pruning_source_class, every: '12h',
                                               mode:   :full, prune_stale: true)

    result = beat_class.new.run!

    expect(result[:error]).to be_nil
    expect(Muni::Store.find(Muni::Records::ServiceRequest, 'stale/space')).to be_nil
    expect(Muni::Store.find(Muni::Records::ServiceRequest, 'fresh/space')).not_to be_nil
  end

  it 'does not prune inventory after a bounded refresh reaches its limit' do
    Muni::Store.upsert(stale_service_request)
    beat_class = Class.new(described_class)
    beat_class.beat('cambridge/overlap_test', source: pruning_source_class, every: '12h',
                                               mode:   :full, limit: 1, prune_stale: true)

    result = beat_class.new.run!

    expect(result).to include(rows_in: 1, error: nil)
    expect(Muni::Store.find(Muni::Records::ServiceRequest, 'stale/space')).not_to be_nil
    expect(Muni::Store.find(Muni::Records::ServiceRequest, 'fresh/space')).not_to be_nil
  end

  it 'advances last_seen to the newest source cursor timestamp' do
    run_overlap_beat(timestamp_cursor_source_class)

    expect(Muni::Store.last_seen('cambridge/overlap_test').to_i).to eq(Time.utc(2026, 6, 1, 12, 0, 0).to_i)
    expect(Muni::Store.find(Muni::Records::ServiceRequest, 'cursor/new').collected_at).not_to be_nil
  end

  it 'enforces source retention after a successful collection' do
    old = stale_service_request
    old.opened_at = Time.now.utc - (31 * 86_400)
    Muni::Store.upsert(old)
    source_class = pruning_source_class
    source_class.source :overlap_test,
                        hall: 'cambridge', emits: Muni::Records::ServiceRequest,
                        base_url: 'https://example.com', retention_days: 30

    run_overlap_beat(source_class)

    expect(Muni::Store.find(Muni::Records::ServiceRequest, 'stale/space', hall: 'cambridge')).to be_nil
    expect(Muni::Store.find(Muni::Records::ServiceRequest, 'fresh/space', hall: 'cambridge')).not_to be_nil
  end

  it 'falls back to record timestamps when a source has no cursor hook' do
    source_class = Class.new(Muni::Source) do
      source :overlap_test,
             hall:     'cambridge',
             emits:    Muni::Records::PoliceLogEntry,
             base_url: 'https://example.com'

      def pull(**_)
        [Muni::Records::PoliceLogEntry.new(
          external_id:    'pd/cursor',
          hall:           'cambridge',
          crime_category: 'INCIDENT',
          occurred_at:    Time.utc(2026, 6, 1, 10, 0, 0),
          reported_at:    Time.utc(2026, 6, 2, 10, 0, 0),
          source_url:     'https://example.com'
        )]
      end
    end

    beat_class = Class.new(described_class)
    beat_class.beat('cambridge/overlap_test', source: source_class, every: '1h')

    beat_class.new.run!

    expect(Muni::Store.last_seen('cambridge/overlap_test').to_i).to eq(Time.utc(2026, 6, 2, 10, 0, 0).to_i)
  end

  it 'advances and resets offset cursors for slow full-source iteration' do
    source_class = cursor_source_class
    beat_class = Class.new(described_class)
    beat_class.beat('cambridge/cursor_test',
                    source: source_class, every: '1h', mode: :full, limit: 2, cursor: :offset)

    beat_class.new.run!
    expect(Muni::Store.meta('cursor:offset:cambridge/cursor_test')).to eq('2')

    beat_class.new.run!
    expect(source_class.seen_offsets).to eq([0, 2])
    expect(Muni::Store.meta('cursor:offset:cambridge/cursor_test')).to eq('0')
  end

  it 'drains resumable offset beats to completion during a Hall seed' do
    source_class = cursor_source_class
    beat_class = Class.new(described_class)
    beat_class.beat('cambridge/cursor_test',
                    source: source_class, every: '1h', mode: :full, limit: 2, cursor: :offset)

    results = Muni::Beats.run_all_once!(hall: 'cambridge', beats: [beat_class])

    expect(source_class.seen_offsets).to eq([0, 2])
    expect(results).to contain_exactly(
      slug: 'cambridge/cursor_test', rows_in: 3, rows_upserted: 3, error: nil
    )
    expect(Muni::Store.meta('cursor:offset:cambridge/cursor_test')).to eq('0')
  end

  it 'registers and runs the cached analytics beat' do
    Muni.boot!
    beat_class = Muni::Registry.beat('cambridge/analytics')

    expect(beat_class.every_seconds).to eq(21_600)

    result = beat_class.new.run!
    row = Muni::Store.analytics_result(
      hall: 'cambridge',
      kind: Muni::Analytics::SERVICE_REQUEST_MODEL,
      key:  Muni::Analytics::DEFAULT_KEY
    )

    expect(result[:error]).to be_nil
    expect(result[:rows_upserted]).to eq(8)
    expect(row[:payload]['status']).to eq('warming')
  end

  it 'registers Hall-neutral analytics and digest beats for Boston' do
    Muni.boot!
    analytics = Muni::Registry.beat('boston/analytics')
    digest = Muni::Registry.beat('boston/digest')
    collector = Muni::Registry.beat('boston/service_requests')
    expired = Muni::Records::ServiceRequest.new(
      external_id: 'boston/expired', hall: 'boston', case_type: 'Pothole', status: 'Closed',
      opened_at: Time.now.utc - (366 * 86_400), source_url: 'https://data.boston.gov'
    )
    Muni::Store.upsert(expired)

    analytics_result = analytics.new.run!
    digest_result = digest.new.run!
    row = Muni::Store.analytics_result(
      hall: 'boston', kind: Muni::Analytics::SERVICE_REQUEST_MODEL, key: Muni::Analytics::DEFAULT_KEY
    )

    expect(analytics_result).to include(rows_upserted: 8, error: nil)
    expect(digest_result[:error]).to be_nil
    expect(row[:payload]['status']).to eq('warming')
    expect(Muni::Store.find(Muni::Records::ServiceRequest, 'boston/expired', hall: 'boston')).to be_nil
    expect(described_class.ordered([digest, analytics, collector])).to eq([collector, analytics, digest])
  end

  def run_overlap_beat(source_class)
    beat_class = Class.new(described_class)
    beat_class.beat('cambridge/overlap_test', source: source_class, every: '1h')
    beat_class.new.run!
  end

  def timestamp_cursor_source_class
    Class.new(Muni::Source) do
      source :overlap_test,
             hall:     'cambridge',
             emits:    Muni::Records::ServiceRequest,
             base_url: 'https://example.com'

      def pull(**_)
        [
          record('cursor/old', Time.utc(2026, 6, 1, 10, 0, 0)),
          record('cursor/new', Time.utc(2026, 6, 1, 12, 0, 0))
        ]
      end

      def cursor_time(record)
        record.updated_at
      end

      def record(id, updated_at)
        Muni::Records::ServiceRequest.new(
          external_id: id,
          hall:        'cambridge',
          case_type:   'Pothole',
          status:      'Open',
          opened_at:   Time.utc(2026, 5, 31, 12, 0, 0),
          updated_at:  updated_at,
          source_url:  'https://example.com'
        )
      end
    end
  end

  def cursor_source_class
    Class.new(Muni::Source) do
      source :cursor_test,
             hall:     'cambridge',
             emits:    Muni::Records::ServiceRequest,
             base_url: 'https://example.com'

      class << self
        attr_accessor :seen_offsets
      end
      self.seen_offsets = []

      def pull(limit: nil, offset: 0, **_)
        self.class.seen_offsets << offset
        Array.new(offset.zero? ? limit : 1) { |i| record(offset, i) }
      end

      def record(offset, index)
        Muni::Records::ServiceRequest.new(
          external_id: "cursor/#{offset}/#{index}",
          hall:        'cambridge',
          case_type:   'Tree maintenance',
          status:      'Open',
          opened_at:   Time.utc(2026, 6, 14, 12, 0, 0),
          source_url:  'https://example.com'
        )
      end
    end
  end

  def stale_service_request
    Muni::Records::ServiceRequest.new(
      external_id:  'stale/space',
      hall:         'cambridge',
      case_type:    'Parking',
      status:       'Open',
      opened_at:    Time.utc(2026, 5, 1),
      last_seen_at: Time.utc(2026, 5, 1),
      source_url:   'https://example.com/stale'
    )
  end

  def pruning_source_class
    Class.new(Muni::Source) do
      source :overlap_test,
             hall:     'cambridge',
             emits:    Muni::Records::ServiceRequest,
             base_url: 'https://example.com'

      def pull(**_)
        [Muni::Records::ServiceRequest.new(
          external_id: 'fresh/space',
          hall:        'cambridge',
          case_type:   'Parking',
          status:      'Open',
          opened_at:   Time.now.utc - 86_400,
          source_url:  'https://example.com/fresh'
        )]
      end
    end
  end
end
