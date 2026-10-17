module Muni
  module Water
    # Small scheduling facts live beside each run, independently of publisher
    # responses and source cursors. Legacy runs deliberately remain unmeasured.
    module RunTiming
      VERSION = 'water-run-timing-v1'.freeze
      ELIGIBLE_TRIGGERS = %w[calendar retry resumed].freeze

      module_function

      def collector(slug, started:)
        state = ScheduleStore.read(slug).to_h
        entry = Thread.current[:muni_scheduler_entry]
        scheduled = entry && entry[:source_slug] == slug
        due = Water.time(state[:last_due_at])
        previous = prior_expectation(slug, due)
        trigger = if scheduled
                    previous&.dig(:timing, 'next_trigger') || (state[:next_run_at] ? 'resumed' : 'startup')
                  else
                    'manual'
                  end
        { invocation: scheduled ? 'scheduler' : 'manual', trigger: trigger,
          due_at: scheduled && due ? due.iso8601(6) : nil, collector_invoked_at: started.iso8601(6),
          expected_from_run_id: previous && previous[:id] }
      end

      def start(slug, started:, scheduling:, reconcile:)
        timing = Water.canonical(scheduling || { invocation: 'manual', trigger: reconcile ? 'reconcile' : 'manual' })
        due = Water.time(timing['due_at'])
        policy = Schedule.new(slug, Catalog.definitions.fetch(slug.delete_prefix(PREFIX))).snapshot
        timing.merge('version' => VERSION, 'started_at' => started.iso8601(6), 'policy' => policy,
                     'delay_seconds' => due && [started - due, 0].max)
              .merge(work_plan(slug, started, reconcile))
      end

      def publication(slug, timing, metadata)
        return timing unless slug == "#{PREFIX}usgs" && timing['planned_work_kind'] != 'reconciliation'

        history = metadata.fetch(:full_reconciliation) { metadata['full_reconciliation'] }
        return timing unless [true, false].include?(history)

        timing.merge('work_kind' => history ? 'backfill' : 'routine', 'work_kind_basis' => 'completed_adapter_window')
      end

      def work_plan(slug, started, reconcile)
        checkpoint = slug == "#{PREFIX}usgs" && !reconcile ? Storage.checkpoint(slug) : {}
        due = Water.time(checkpoint['routine_due_at'])
        kind = checkpoint['history_cursor'] && due && due > started ? 'backfill' : 'routine'
        kind = 'reconciliation' if reconcile
        { 'work_kind' => kind, 'planned_work_kind' => kind, 'work_kind_basis' => 'checkpoint_at_start',
          'routine_due_at' => due&.iso8601(6), 'routine_delay_seconds' => due && [started - due, 0].max }
      end

      # Called in the same short transaction that releases the matching lease.
      # JSON_SET only touches the run's small metadata, never a source checkpoint.
      def complete(run_id, due, trigger)
        value = Sequel.lit("json_set(metadata, '$.scheduling.next_due_at', ?, '$.scheduling.next_trigger', ?)",
                           due.utc.iso8601(6), trigger)
        Storage.db[:water_runs].where(id: run_id).update(metadata: value)
      end

      def prior_expectation(slug, due)
        return unless due

        row = timing_rows(slug).where(Sequel.lit("json_extract(metadata, '$.scheduling.next_due_at') = ?",
                                                 due.utc.iso8601(6))).order(Sequel.desc(:id)).first
        decode(row) if row
      end

      def timing_rows(slug)
        Storage.db[:water_runs].where(source_slug: slug)
               .select(:id, :started_at, :status, Sequel.lit("json_extract(metadata, '$.scheduling') AS timing"))
      end

      def decode(row)
        row.merge(timing: row[:timing] ? JSON.parse(row[:timing]) : {})
      end
    end

    class ScheduleHistory
      WINDOW_SECONDS = 86_400

      def initialize(slug, now:)
        @slug = slug
        @now = now
        @cutoff = now - WINDOW_SECONDS
      end

      def call
        dataset = RunTiming.timing_rows(@slug)
        rows = dataset.where(started_at: @cutoff..@now).order(:id).all.map { |row| RunTiming.decode(row) }
        measured = rows.select { |row| row[:timing]['version'] == RunTiming::VERSION }
        eligible = measured.select { |row| eligible?(row[:timing]) }
        delays = eligible.map { |row| delay(row) }.sort
        first = first_recorded_at(dataset)
        { window_start: @cutoff, window_end: @now, recorded_since: first,
          covers_full_window: !first.nil? && first <= @cutoff && rows.length == measured.length,
          measured_runs: measured.length,
          legacy_unmeasured_runs: rows.length - measured.length, eligible_starts: delays.length,
          failed_starts: eligible.count { |row| row[:status] == 'failed' },
          p95_start_delay_seconds: percentile(delays), max_start_delay_seconds: delays.last,
          starts_over_60_seconds: delays.count { |delay| delay > 60 },
          excluded_runs: measured.length - eligible.length,
          timing_groups: timing_groups(eligible),
          attribution: 'Timing categories do not identify the cause of a delay.',
          expectations: expectations(dataset, rows) }
      end

      private

      def eligible?(timing)
        timing['invocation'] == 'scheduler' && timing['work_kind'] == 'routine' &&
          RunTiming::ELIGIBLE_TRIGGERS.include?(effective_trigger(timing)) && timing['delay_seconds'].is_a?(Numeric)
      end

      def effective_trigger(timing)
        timing['trigger'] == 'backfill' && timing['routine_due_at'] ? 'calendar' : timing['trigger']
      end

      def delay(row)
        timing = row[:timing]
        timing['trigger'] == 'backfill' ? timing.fetch('routine_delay_seconds') : timing.fetch('delay_seconds')
      end

      def timing_groups(rows)
        routine = rows.select do |row|
          row[:status] == 'complete' && %w[calendar resumed].include?(effective_trigger(row[:timing]))
        end
        { successful_calendar_or_resumed: timing_statistics(routine),
          retry:                          timing_statistics(rows.select { |row| row[:timing]['trigger'] == 'retry' }),
          failed:                         timing_statistics(rows.select { |row| row[:status] == 'failed' }) }
      end

      def timing_statistics(rows)
        delays = rows.map { |row| delay(row) }.sort
        { starts: rows.length, p95_start_delay_seconds: percentile(delays), max_start_delay_seconds: delays.last }
      end

      def first_recorded_at(dataset)
        value = dataset.where(Sequel.lit("json_extract(metadata, '$.scheduling.version') = ?", RunTiming::VERSION))
                       .min(:started_at)
        Water.time(value)
      end

      def percentile(values)
        values[(values.length * 0.95).ceil - 1] unless values.empty?
      end

      def expectations(dataset, rows)
        # Only the final decision preceding the window can still be outstanding;
        # earlier decisions were consumed or superseded by subsequent collectors.
        previous = previous_decision(dataset)
        candidates = rows.dup
        candidates.unshift(RunTiming.decode(previous)) if previous
        expected = candidates.select { |row| expected?(row[:timing]) }
        linked = rows.to_h { |row| [row[:timing]['expected_from_run_id'], row] }
        boundary_consumer(dataset, previous, linked) if previous
        expectation_counts(expected, linked)
      end

      def previous_decision(dataset)
        recorded = Sequel.lit("json_extract(metadata, '$.scheduling.next_due_at') IS NOT NULL")
        dataset.where(Sequel[:started_at] < @cutoff).where(recorded).order(Sequel.desc(:id)).first
      end

      def expectation_counts(expected, linked)
        overdue = expected.reject { |row| linked.key?(row[:id]) }
        { basis:                 'recorded_next_check_decisions',
          eligible_due:          expected.count { |row| Water.time(row[:timing]['next_due_at']) >= @cutoff },
          overdue_without_start: overdue.length,
          overdue_before_window: overdue.count { |row| Water.time(row[:timing]['next_due_at']) < @cutoff },
          oldest_overdue_at:     overdue.map { |row| row[:timing]['next_due_at'] }.min,
          superseded_manually:   expected.count do |row|
            linked[row[:id]]&.dig(:timing, 'invocation') == 'manual'
          end,
          limitation:            'Additional calendar slots skipped during outages are not reconstructed.' }
      end

      def boundary_consumer(dataset, previous, linked)
        consumer = dataset.where(Sequel.lit("json_extract(metadata, '$.scheduling.expected_from_run_id') = ?",
                                            previous[:id])).first
        linked[previous[:id]] = RunTiming.decode(consumer) if consumer
      end

      def expected?(timing)
        due = Water.time(timing['next_due_at'])
        RunTiming::ELIGIBLE_TRIGGERS.include?(timing['next_trigger']) && due && due <= @now
      end
    end
  end
end
