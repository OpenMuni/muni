require 'muni/water/schedule'

module Muni
  module Water
    class Collector < Muni::Beat
      def self.schedule_policy
        Schedule.new(slug, Catalog.definitions.fetch(slug.delete_prefix(PREFIX)))
      end

      def run!
        return { rows_in: 0, rows_upserted: 0, error: nil } unless Water.enabled?
        return { rows_in: 0, rows_upserted: 0, error: nil, skipped: true } unless Water.processing_enabled?

        started = Time.now.utc
        token = ScheduleStore.acquire(self.class.slug, now: started)
        unless token
          saved = ScheduleStore.read(self.class.slug)
          due = Water.time(saved[:lease_expires_at] || saved[:next_run_at]) || (started + ScheduleStore::BUSY_SECONDS)
          return { rows_in: 0, rows_upserted: 0, error: nil, skipped: true,
                   next_run_at: [due, started + 1].max }
        end
        previous_lease = Thread.current[:muni_water_lease]
        Thread.current[:muni_water_lease] = [self.class.slug, token]
        result = execute(started)
      rescue StandardError => e
        result = { rows_in: 0, rows_upserted: 0, error: e }
      ensure
        if token
          begin
            finish_run(token, result)
          ensure
            Thread.current[:muni_water_lease] = previous_lease
          end
        end
      end

      private

      def finish_run(token, result)
        now = Time.now.utc
        policy = self.class.schedule_policy
        timing = policy.finish(now, result && result[:error])
        trigger = policy.trigger(now, result && result[:error], timing[:next_run_at])
        if result && !result[:error] && Storage.checkpoint(self.class.slug).dig('metadata', 'backfill_pending')
          continuation = now + 5
          trigger = 'backfill' if continuation < timing[:next_run_at]
          timing[:next_run_at] = [timing[:next_run_at], continuation].min
        end
        ScheduleStore.complete(self.class.slug, token, **timing, run_id:       result && result[:run_id],
                                                                 next_trigger: trigger)
        result[:next_run_at] = timing[:next_run_at] if result
      end

      def execute(started)
        timing = RunTiming.collector(self.class.slug, started: started)
        result = Ingestor.new(self.class.slug.delete_prefix(PREFIX)).run(scheduling: timing)
        unless result[:error]
          Muni::Store.mark_checked(self.class.slug, started,
                                   changed: result[:rows_upserted].positive?)
        end
        Muni::Store.log_beat_run(slug: self.class.slug, started_at: started, ended_at: Time.now.utc,
                                 **result.slice(:rows_in, :rows_upserted, :error))
        result
      end
    end

    def self.register!
      return unless enabled?

      Catalog.definitions.each do |id, definition|
        next if Muni::Registry.beat("#{PREFIX}#{id}")

        source = Class.new(Muni::Source)
        source.source(id, waterbody: 'charles', municipalities: HALLS, emits: Evidence, base_url: definition[:url],
                      cadence: "#{definition[:cadence]}s", criticality: :optional, categories: [:water],
                      catalog: { label: definition[:label], scope: 'waterbody', managed_ingestion: true })
        Class.new(Collector).beat(source.slug, source: source, every: source.cadence, mode: :full)
      end
    end
  end
end
