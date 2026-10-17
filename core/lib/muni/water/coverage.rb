module Muni
  module Water
    class Coverage
      def initialize(now: Time.now.utc)
        @now = now
      end

      def call
        Storage.db.transaction do
          rows = Catalog.definitions.map { |id, definition| source(id, definition) } + Catalog::GAPS
          rows.map { |row| operating_state(row) }
        end
      end

      private

      def operating_state(row)
        state = { processing_enabled: Water.processing_enabled?, presentation_enabled: Water.presentation_enabled? }
        unless state[:processing_enabled] || !row[:source_slug]
          state.merge!(collection_status:      'paused',
                       collection_explanation: 'Scheduled water collection and calculations are paused.')
        end
        row.merge(state)
      end

      def source(id, definition)
        slug = "#{PREFIX}#{id}"
        checkpoint = Storage.checkpoint_fields(slug, %w[last_success_at last_checked_at monitoring_started_at
                                                        publisher_observations metadata boating_season])
        last = Water.time(checkpoint['last_success_at'])
        bounds = observation_bounds(slug)
        latest_run = Storage.db[:water_runs].where(source_slug: slug).order(Sequel.desc(:id)).first
        interrupted = interrupted?(latest_run, last, definition)
        { id: id, source_slug: slug, label: definition[:label], source_url: definition[:url],
          status: freshness(id, definition, checkpoint, Water.time(bounds[:newest]), last),
          collection_status: interrupted ? 'collection_interrupted' : 'checking',
          collection_explanation: interrupted ? 'Collection interrupted; upstream availability unknown.' : nil,
          monitoring_started_at: checkpoint['monitoring_started_at'], last_success_at: last,
          last_checked_at: checkpoint['last_checked_at'] || last,
          publisher_changed_at: publisher_changed_at(checkpoint),
          observed_editions: checkpoint['publisher_observations'],
          newest_observation_date: bounds[:newest_date], oldest_observation_date: bounds[:oldest_date],
          newest_observation_at: Water.time(bounds[:newest]), oldest_observation_at: Water.time(bounds[:oldest]),
          records: bounds.fetch(:records, 0), cadence_seconds: definition[:cadence], calendar: definition[:calendar],
          expected_interval_seconds: definition[:interval], publication_cadence: definition[:publication_cadence],
          source_metadata: checkpoint['metadata'], allowance_seconds: definition[:grace], parser_version: VERSION,
          coverage: 'Only the selected locations and sources checked.' }
          .merge(run_metadata(latest_run)).merge(processing(slug)).merge(scheduling(slug))
      end

      def run_metadata(run)
        { last_run_changes: run && run[:changes], last_run_records: run && run[:records],
          last_error: run && run[:error] }
      end

      def observation_bounds(slug)
        rows = Storage.evidence.where(source_slug: slug)
        # Separate scalar extrema let SQLite seek the ordered source indexes.
        # Combining them with COUNT forces a scan of every large evidence row.
        { newest: rows.max(:observed_at), oldest: rows.min(:observed_at),
          newest_date: rows.max(:observed_date), oldest_date: rows.min(:observed_date), records: rows.count }
      end

      def interrupted?(run, last, definition)
        !last || run&.fetch(:status) == 'failed' || @now - last > definition[:cadence] * 2
      end

      def publisher_changed_at(checkpoint)
        observations = checkpoint['publisher_observations'] || {}
        return observations['changed_at'] if observations['basis'] == 'publisher_timestamp'

        checkpoint.dig('metadata', 'source_last_edited_at')
      end

      def scheduling(slug)
        schedule = ScheduleStore.read(slug).to_h
        due, started = schedule.values_at(:last_due_at, :last_started_at).map { |time| Water.time(time) }
        { next_check_at: Water.time(schedule[:next_run_at]), consecutive_failures: schedule[:failure_count].to_i,
          collection_delay_seconds: due && started && [started - due, 0].max,
          start_timing_24h: ScheduleHistory.new(slug, now: @now).call }
      end

      def processing(slug)
        batch = Storage.db[:water_batches].where(source_slug: slug).order(Sequel.desc(:started_at)).first
        { processing_status: batch && batch[:status], writer_seconds: batch && batch[:writer_seconds],
          processing_cost: batch&.slice(:normalization_seconds, :normalization_allocations, :normalization_gc_ms,
                                        :writer_wait_seconds, :calculation_seconds, :calculation_allocations,
                                        :calculation_gc_ms),
          phases: batch&.slice(:retrieved_at, :normalized_at, :published_at, :calculated_at),
          calculation_backlog: Storage.db[:water_calculation_jobs].where(source_slug: slug,
                                                                         status:      %w[pending failed
                                                                                         running]).count }
      end

      def freshness(id, definition, checkpoint, newest, checked)
        return 'insufficient_evidence' unless checked
        return 'out_of_season' if checkpoint['boating_season'] == false
        return (@now - checked > definition[:grace] ? 'stale' : 'current_publisher_state') if id == 'crwa_boathouses'
        return 'historical_data_only' unless definition[:interval]
        return 'insufficient_evidence' unless newest

        @now - newest > definition[:grace] ? 'stale' : 'current'
      end
    end
  end
end
