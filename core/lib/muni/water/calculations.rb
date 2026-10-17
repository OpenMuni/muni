module Muni
  module Water
    # Publication and calculations have separate failure states. Jobs are durable
    # and idempotent; retrying a job never repeats collection or source revisions.
    class Calculations
      RETRY_DELAYS = [30, 120, 600, 3600].freeze

      def initialize(now: Time.now.utc)
        @now = now
      end

      def drain(slug: nil, limit: 10)
        self.class.with_lock do
          jobs = Storage.db[:water_calculation_jobs].where(status: %w[pending failed running])
          jobs = jobs.where(source_slug: slug) if slug
          jobs.where(Sequel.|({ retry_at: nil }, Sequel[:retry_at] <= @now))
              .order(:id).limit(limit).all.map do |job|
            result = calculate(job)
            Thread.current[:muni_scheduler_yield]&.call
            result
          end
        end || []
      rescue StandardError => e
        # Publication has already committed. A worker/storage failure must not
        # retroactively turn it into a failed collection or discard its evidence.
        Muni::Logger.instance.error("Water calculation worker: #{e.class}: #{e.message}")
        [{ calculation_error: e }]
      end

      def self.with_lock
        File.open("#{Muni::Config.db_path}.water-calculations.lock", File::RDWR | File::CREAT, 0o600) do |lock|
          next unless lock.flock(File::LOCK_EX | File::LOCK_NB)

          yield
        ensure
          lock.flock(File::LOCK_UN)
        end
      end

      private

      def calculate(job)
        token = SecureRandom.uuid
        attempts = job[:attempts].to_i + 1
        Muni::Store.with_writer do
          Storage.db[:water_calculation_jobs].where(id: job[:id])
                 .update(status: 'running', attempts: attempts, claimed_at: @now, claim_token: token, retry_at: nil)
        end
        payload = JSON.parse(job[:payload])
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        gc = GC.stat
        DailySummaries.new(now: @now).refresh(payload.fetch('dirty', []))
        Signals.new(now: @now).recalculate(slug: job[:source_slug], dirty: payload.fetch('dirty', []),
                                           revision_range: payload['revision_range'])
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        metrics = { calculation_seconds:     elapsed,
                    calculation_allocations: GC.stat[:total_allocated_objects] - gc[:total_allocated_objects],
                    calculation_gc_ms:       GC.stat[:time] - gc[:time] }
        complete(job, token, metrics)
        metrics
      rescue StandardError => e
        fail_job(job, token, attempts, e)
        { calculation_error: e }
      end

      def complete(job, token, metrics)
        Muni::Store.with_writer do
          Storage.db[:water_calculation_jobs].where(id: job[:id], claim_token: token)
                 .update(status: 'complete', error: nil, completed_at: Time.now.utc, claim_token: nil, retry_at: nil)
          Storage.db[:water_batches].where(id: job[:batch_id])
                 .update(metrics.merge(calculated_at: Time.now.utc, status: 'complete', error: nil))
        end
      end

      def fail_job(job, token, attempts, error)
        Muni::Store.with_writer do
          delay = RETRY_DELAYS[[attempts.to_i - 1, RETRY_DELAYS.length - 1].min]
          Storage.db[:water_calculation_jobs].where(id: job[:id], claim_token: token)
                 .update(status: 'failed', error: error.message, retry_at: @now + delay, claim_token: nil)
          Storage.db[:water_batches].where(id: job[:batch_id]).update(status: 'calculation_failed',
                                                                      error:  error.message)
        end
      end
    end
  end
end
