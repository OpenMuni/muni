require 'json'

module Muni
  # Bounded, restartable reconciliation. Missing records remain unchanged.
  class ServiceRequestReconciliation
    PAGE_SIZE = 200
    PAUSE_SECONDS = 0.25

    def initialize(source, apply: false, max_batches: 4, page_size: PAGE_SIZE)
      @source = source
      @apply = apply
      @max_batches = Integer(max_batches).clamp(1, 100)
      @page_size = Integer(page_size).clamp(1, 500)
      @hall = source.class.hall
    end

    def run
      reports = []
      # Updates are ordered by source modification time, never creation time.
      reports.concat(updates) if @source.respond_to?(:lifecycle_updates)
      reports.concat(sweep('recent', @max_batches))
      reports.concat(sweep('active', @max_batches))
      reports.concat(sweep('recent_closed', 1)) # reopenings that could become map-eligible
      reports.concat(sweep('all', 1)) # includes closed tickets to detect reopening
      { hall: @hall, apply: @apply, batches: reports }
    end

    private

    def sweep(lane, budget)
      key = "lifecycle:v1:#{@hall}:#{lane}"
      expected = Store.meta(key)
      state = JSON.parse(expected || '{}')
      reports = []
      budget.times do
        ds = sweep_dataset(lane)
        ds = ds.where { external_id > state['after'] } if state['after']
        rows = ds.order(:external_id).limit(@page_size).all
        records = rows.empty? ? [] : @source.lifecycle_lookup(rows)
        state = { 'after'      => rows.length < @page_size ? nil : rows.last[:external_id],
                  'checked_at' => Time.now.utc.iso8601(6) }
        reports << persist(records, rows, key, expected, state)
        expected = JSON.generate(state)
        break if rows.length < @page_size
      end
      reports
    end

    def sweep_dataset(lane)
      dataset = Store.db[:service_requests].where(hall: @hall)
      if %w[active recent].include?(lane)
        dataset = dataset.where(closed_at: nil)
                         .exclude(Sequel.function(:lower, :status) => ServiceRequestPolicy::CLOSED_STATUSES)
      end
      if lane == 'recent_closed'
        terminal = Sequel.~(closed_at: nil) |
                   Sequel.expr(Sequel.function(:lower, :status) => ServiceRequestPolicy::CLOSED_STATUSES)
        dataset = dataset.where(terminal)
      end
      return dataset unless %w[recent recent_closed].include?(lane)

      now = Time.now.utc
      dataset.where(Sequel.lit('opened_at >= ? AND opened_at <= ?', now - (30 * 86_400), now))
    end

    def updates
      key = "lifecycle:v1:#{@hall}:updates"
      expected = Store.meta(key)
      state = JSON.parse(expected || '{}')
      reports = []
      @max_batches.times do
        records, checkpoint = @source.lifecycle_updates(state, limit: @page_size)
        rows = Store.db[:service_requests].where(hall: @hall, external_id: records.map(&:external_id)).all
        reports << persist(records, rows, key, expected, checkpoint)
        expected = JSON.generate(checkpoint)
        state = checkpoint
        break if state['after'].nil?
      end
      reports
    end

    def persist(records, rows, key, expected, checkpoint)
      before = rows.to_h { |row| [row[:external_id], row] }
      changes = records.filter_map do |record|
        old = before[record.external_id]
        next if old && %i[status closed_at opened_at updated_at].all? { |field| old[field] == record.to_h[field] }

        { external_id: record.external_id, before: old&.slice(:status, :closed_at, :opened_at, :updated_at),
          after: record.to_h.slice(:status, :closed_at, :opened_at, :updated_at), evidence: record.lifecycle_evidence }
      end
      report = { lane: key, inspected: rows.length, found: records.length,
                 missing: before.keys - records.map(&:external_id), changes: changes, persisted: 0 }
      checkpoint['last_batch'] = { 'checked_at' => Time.now.utc.iso8601(6), 'inspected' => rows.length,
                                   'found' => records.length, 'missing' => report[:missing] }
      if @apply
        missing = rows.select { |row| report[:missing].include?(row[:external_id]) }
        report[:persisted] = Store.persist_lifecycle_batch(records, key: key, expected: expected,
                                                          checkpoint: checkpoint, missing: missing)
      end
      sleep PAUSE_SECONDS
      report
    end
  end
end
