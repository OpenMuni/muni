require 'muni/water/calculation_invalidation'
require 'muni/water/run_timing'

module Muni
  module Water
    # Publication coordinates collection, normalization, persistence and calculation.
    # rubocop:disable-next Metrics/ClassLength
    class Ingestor
      attr_reader :slug

      def initialize(id, now: Time.now.utc)
        @id = id
        @slug = "#{PREFIX}#{id}"
        @now = now
      end

      def run(adapter: nil, reconcile: false, scheduling: nil)
        lock_path = "#{Muni::Config.db_path}.water-#{Water.hash(slug)[0, 16]}.lock"
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          return { rows_in: 0, rows_upserted: 0, error: Error.new('Source collection already running') } unless
            lock.flock(File::LOCK_EX | File::LOCK_NB)

          @reconcile = reconcile
          @scheduling = scheduling
          adapter = nil if reconcile
          collect_and_publish(adapter)
        ensure
          lock.flock(File::LOCK_UN)
        end
      end

      def collect_and_publish(adapter)
        result = collect_and_commit(adapter)
        result[:error] ? result : calculate(result)
      end

      def collect_and_commit(adapter)
        run_id = start_run
        adapter ||= Adapters.build(@id, checkpoint: Storage.checkpoint(slug), now: @now, reconcile: @reconcile == true)
        prepared = prepare_collection(adapter)
        changes = commit(adapter, run_id, prepared)
        { rows_in: prepared[:record_count], rows_upserted: changes, error: nil, batch_id: @batch_id, run_id: run_id }
      rescue StandardError => e
        fail_run(run_id, adapter, e) if run_id
        { rows_in: 0, rows_upserted: 0, error: e, batch_id: @batch_id, run_id: run_id }
      ensure
        prepared&.fetch(:writer)&.close
      end

      # Keep all pre-commit preparation in one measured phase.
      # rubocop:disable-next Metrics/AbcSize
      def prepare_collection(adapter)
        records = adapter.collect
        retrieved_at = Time.now.utc
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        gc = GC.stat
        records.each { |record| validate!(record) }
        records = unique_records(records)
        reconcile_events!(records)
        writer = EvidenceWriter.new(now: @now).prepare(records)
        invalidation = CalculationInvalidation.new(DailySummaries.dirty(writer.changes), now: @now)
        responses = prepare_responses(adapter.client.responses)
        manifest = ResponseArchive.manifest(responses)
        batch = { status: 'prepared', retrieved_at: retrieved_at,
                  normalized_at: Time.now.utc, manifest: Water.json(manifest) }
                .merge(SourceEditions.batch_identity(slug, adapter, records))
        state = PreparedPublication.new(slug, adapter, publisher_observations: JSON.parse(batch[:source_edition]),
                                        dirty: invalidation.dirty, now: @now)
        run_metadata = prepared_run_metadata(adapter)
        batch.merge!(normalization_seconds:     Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
                     normalization_allocations: GC.stat[:total_allocated_objects] - gc[:total_allocated_objects],
                     normalization_gc_ms:       GC.stat[:time] - gc[:time])
        Muni::Store.with_writer do
          Storage.db[:water_batches].where(id: @batch_id).update(batch)
        end
        { record_count: records.length, writer: writer, dirty: invalidation.dirty,
          invalidation: invalidation, responses: responses,
          state: state, run_metadata: run_metadata }
      rescue StandardError
        writer&.close
        raise
      end

      def calculate(result)
        Calculations.new(now: @now).drain(slug: slug)
        job = Storage.db[:water_calculation_jobs].where(batch_id: @batch_id).first
        result.merge(calculation_status: job && job[:status], calculation_error: job && job[:error])
      rescue StandardError => e
        calculation_failed(e)
        result.merge(calculation_status: 'failed', calculation_error: e.message)
      end

      def commit(_adapter, run_id, prepared)
        started = nil
        waiting = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        changes = Muni::Store.with_writer do
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          Storage.db.transaction do
            first_revision = (Storage.db[:water_revisions].max(:id) || 0) + 1
            changed = prepared[:writer].publish
            prepared[:invalidation].publish
            complete_publication(run_id, prepared, changed)
            queue_calculation(prepared[:state], first_revision)
            changed
          end
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        record_writer_duration(elapsed, started - waiting)
        changes
      end

      # Must be called inside the ingestion transaction. Initial publication is
      # version 1; last-checked timestamps are never part of semantic identity.
      def persist(record) = EvidenceWriter.new(now: @now).call([record])

      def import_advisory(attributes)
        attrs = Water.canonical(attributes)
        %w[id issuer source_url scope reviewer title].each do |key|
          raise Error, "Advisory requires #{key}" if attrs[key].to_s.strip.empty?
        end
        raise Error, 'Advisory source must be an HTTP(S) URL' unless attrs['source_url'].match?(%r{\Ahttps?://})
        raise Error, 'Advisory scope must be charles or a catalog location/reach' unless valid_scope?(attrs['scope'])

        issued = attrs['issued_at'] && Time.iso8601(attrs['issued_at'])
        expiry = attrs['expires_at'] && Time.iso8601(attrs['expires_at'])
        raise Error, 'Advisory expiry precedes issuance' if issued && expiry && expiry < issued

        row = { external_id: Water.hash([slug, attrs['issuer'], attrs['id']]), source_slug: slug,
                waterbody: 'charles', kind: 'official_advisory', location_id: attrs['scope'],
                observed_at: issued, published_at: issued, fetched_at: @now, source_url: attrs['source_url'],
                status: attrs.fetch('status', 'published'), parser_version: VERSION, raw: attrs,
                payload: attrs.merge('reviewed_at' => @now.iso8601) }
        Muni::Store.with_writer { Storage.db.transaction { persist(row) } }
        row
      end

      private

      def prepared_run_metadata(adapter)
        timing = RunTiming.publication(slug, @run_timing, adapter.metadata)
        Water.json(adapter.metadata.merge('scheduling' => timing))
      end

      def start_run
        @batch_id = SecureRandom.uuid
        started = Time.now.utc
        @run_timing = RunTiming.start(slug, started: started, scheduling: @scheduling, reconcile: @reconcile)
        metadata = Water.json('scheduling' => @run_timing)
        Muni::Store.with_writer do
          id = Storage.db[:water_runs].insert(source_slug: slug, started_at: started, status: 'running',
                                              metadata: metadata)
          Storage.db[:water_batches].insert(id: @batch_id, run_id: id, source_slug: slug,
                                            status: 'retrieving', started_at: Time.now.utc,
                                            signature: Water.hash([@id, VERSION, Normalization::VERSION]))
          id
        end
      end

      def complete_publication(run_id, prepared, changes)
        prepared[:state].publish
        archive_prepared_responses(prepared[:responses])
        Storage.db[:water_pending_pages].where(source_slug: slug).delete
        run = { status: 'complete', ended_at: Time.now.utc, records: prepared[:record_count],
                changes: changes, metadata: prepared[:run_metadata] }
        Storage.db[:water_runs].where(id: run_id).update(run)
        Storage.db[:water_batches].where(id: @batch_id).update(status: 'published', published_at: Time.now.utc)
      end

      def queue_calculation(state, first_revision)
        last_revision = Storage.db[:water_revisions].max(:id) || 0
        payload = state.calculation_payload(first_revision, last_revision)
        Storage.db[:water_calculation_jobs].insert(batch_id: @batch_id, source_slug: slug,
                                                   payload: payload,
                                                   created_at: Time.now.utc, status: 'pending')
      end

      def calculation_failed(error)
        Muni::Store.with_writer do
          Storage.db[:water_calculation_jobs].where(batch_id: @batch_id).exclude(status: 'complete')
                 .update(status: 'failed', error: error.message, retry_at: @now + 30)
          Storage.db[:water_batches].where(id: @batch_id).exclude(status: 'complete')
                 .update(status: 'calculation_failed', error: error.message)
        end
      rescue StandardError => e
        Muni::Logger.instance.error("Could not retain water calculation failure: #{e.class}: #{e.message}")
      end

      def record_writer_duration(elapsed, waited)
        Muni::Store.with_writer do
          Storage.db[:water_batches].where(id: @batch_id).update(writer_seconds: elapsed, writer_wait_seconds: waited)
        end
      rescue StandardError => e
        Muni::Logger.instance.error("Could not retain water publication timing: #{e.class}: #{e.message}")
      end

      def fail_run(run_id, adapter, error)
        responses = adapter ? prepare_responses(adapter.client.responses) : []
        Muni::Store.with_writer do
          Storage.db[:water_runs].where(id: run_id).update(status: 'failed', ended_at: Time.now.utc,
                                                           error: error.message)
          archive_prepared_responses(responses)
          retryable = error.is_a?(Faraday::Error) || (error.respond_to?(:retryable?) && error.retryable?)
          Storage.db[:water_pending_pages].where(source_slug: slug).delete unless retryable
          Storage.db[:water_batches].where(id: @batch_id).update(status: 'failed', error: error.message)
        end
        Signals.new(now: @now).collection(slug)
      end

      def unique_records(records)
        unique = {}
        records.each do |record|
          prior = unique[record[:external_id]]
          if prior && Water.hash(prior.except(:fetched_at, :parser_version)) !=
                      Water.hash(record.except(:fetched_at, :parser_version))
            raise Error, 'Source returned conflicting records with the same identity'
          end

          unique[record[:external_id]] ||= record
        end
        unique.values
      end

      def valid_scope?(scope)
        scope == 'charles' || %w[reach-2 reach-3 reach-4 reach-5].include?(scope) ||
          Storage.db[:water_locations].where(id: scope).any?
      end

      def validate!(record)
        %i[external_id source_slug kind location_id source_url parser_version raw].each do |key|
          raise Error, "Invalid water record: missing #{key}" if record[key].nil? || record[key] == ''
        end
        raise Error, 'Record belongs to a different source' unless record[:source_slug] == slug
        raise Error, 'Non-finite measurement' if record[:value] && !record[:value].finite?
      end

      def reconcile_events!(records)
        events = records.select { |row| row[:kind] == 'discharge' }
        groups = events.group_by do |row|
          [row[:location_id], row[:payload][:event_date]]
        end
        groups.each do |(location, date), incoming|
          existing = Storage.evidence.where(source_slug: slug, kind: 'discharge', location_id: location)
                            .all.map { |row| Storage.decode(row) }.select do |row|
            row.dig('payload',
                    'event_date') == date
          end
          next if existing.empty?

          reconcile_event_group(incoming, existing)
        end
      end

      def reconcile_event_group(incoming, existing)
        unmatched = incoming.reject { |row| existing.any? { |old| old['external_id'] == row[:external_id] } }
        unmatched.each do |row|
          candidates = existing.select { |old| same_notice?(row, old) }
          if candidates.length == 1 && incoming.one? { |item| same_notice?(item, candidates.first) }
            reuse_notice_identity(row, candidates.first)
          elsif notice_documents(row[:payload]).empty? || !candidates.empty?
            row[:status] = 'needs_review'
            reason = 'Same-day notices may describe distinct events; source identity requires review.'
            row[:payload].merge!(countable: false, event_candidates: existing.map { |old| old['external_id'] },
                                 review_reason: reason)
          end
        end
      end

      def reuse_notice_identity(row, previous)
        previous_id = previous.dig('payload', 'source_record_id')
        row[:payload][:previous_source_record_id] = if row[:payload][:source_record_id] == previous_id
                                                      previous.dig('payload', 'previous_source_record_id')
                                                    else
                                                      previous_id
                                                    end
        row[:external_id] = previous['external_id']
      end

      def same_notice?(incoming, existing)
        reference = incoming[:payload][:supersedes_evidence_id]
        return true if reference && reference == existing['external_id']

        current_id = incoming[:payload][:source_record_id]
        return true if current_id && current_id == existing.dig('payload', 'source_record_id')

        notice_documents(incoming[:payload]).intersect?(notice_documents(existing['payload']))
      end

      def notice_documents(payload)
        Array(payload[:notice_urls] || payload['notice_urls']).select do |url|
          URI(url).path.downcase.end_with?('.pdf')
        rescue URI::InvalidURIError
          false
        end
      end

      def prepare_responses(responses) = ResponseArchive.prepare(slug, responses, now: @now)

      def archive_prepared_responses(responses) = ResponseArchive.publish(slug, responses, now: @now)
    end
  end
end
