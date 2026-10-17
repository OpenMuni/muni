module Muni
  module Water
    # Re-interpret retained evidence without pretending the publisher was checked.
    class Reconciler
      def initialize(now: Time.now.utc)
        @now = now
      end

      def normalize(source: nil, batch_size: 1000)
        dataset = Storage.evidence
        dataset = dataset.where(source_slug: source.start_with?(PREFIX) ? source : "#{PREFIX}#{source}") if source
        report = { before: dataset.count, changed: 0, batches: 0, normalization_version: Normalization::VERSION }
        dataset.select(:source_slug).distinct.select_map(:source_slug).each do |slug|
          normalize_source(slug, report, batch_size)
        end
        report.merge(after: dataset.count, daily_summaries: Storage.db[:water_daily_summaries].count,
                     unresolved: dataset.where(status: 'needs_review').count)
      end

      def normalize_source(slug, report, batch_size)
        lock_path = "#{Muni::Config.db_path}.water-#{Water.hash(slug)[0, 16]}.lock"
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          raise Error, 'Source collection already running' unless lock.flock(File::LOCK_EX | File::LOCK_NB)

          ids = Storage.evidence.where(source_slug: slug).order(:observed_at, :external_id).select_map(:external_id)
          ids.each_slice(batch_size) do |batch|
            rows = Storage.evidence.where(external_id: batch).all.map do |row|
              Storage.decode(row).transform_keys(&:to_sym).merge(row.slice(:observed_at, :published_at, :fetched_at))
            end
            writer = EvidenceWriter.new(now: @now).prepare(rows)
            next if writer.prepared.empty?

            publish_normalization(slug, writer, report)
          ensure
            writer&.close
            Thread.current[:muni_scheduler_yield]&.call
          end
        end
        Calculations.new(now: @now).drain(slug: slug, limit: 100_000)
      end

      def publish_normalization(slug, writer, report)
        batch_id = SecureRandom.uuid
        invalidation = CalculationInvalidation.new(DailySummaries.dirty(writer.changes), now: @now)
        identity = batch_identity(slug, writer)
        started = nil
        Muni::Store.with_writer do
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          Storage.db.transaction do
            first = (Storage.db[:water_revisions].max(:id) || 0) + 1
            changed = writer.publish
            invalidation.publish
            batch = { id: batch_id, source_slug: slug, status: 'published', started_at: @now,
                      normalized_at: Time.now.utc, published_at: Time.now.utc,
                      manifest: Water.json(kind: 'retained_evidence_normalization') }.merge(identity)
            Storage.db[:water_batches].insert(batch)
            queue_calculation(slug, batch_id, invalidation.dirty, first)
            report[:changed] += changed
            report[:batches] += 1
          end
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        Muni::Store.with_writer { Storage.db[:water_batches].where(id: batch_id).update(writer_seconds: elapsed) }
      end

      def batch_identity(slug, writer)
        query = Water.hash([slug, writer.prepared.map { |entry| entry[:record][:external_id] }])
        parser = Water.hash([VERSION, Normalization::VERSION])
        { query_signature: query, parser_signature: parser, signature: Water.hash([query, parser]) }
      end

      def queue_calculation(slug, batch_id, dirty, first)
        payload = Water.json(dirty: dirty, revision_range: [first, Storage.db[:water_revisions].max(:id)])
        Storage.db[:water_calculation_jobs].insert(batch_id: batch_id, source_slug: slug, created_at: @now,
                                                   status: 'pending', payload: payload)
      end
    end
  end
end
