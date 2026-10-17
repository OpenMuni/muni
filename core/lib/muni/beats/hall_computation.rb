require 'muni/beat'

module Muni
  module Beats
    # Shared lifecycle for Hall-scoped computed products. Beat ordering keeps
    # these jobs behind collectors during both startup staggering and seeds.
    class HallComputation < Muni::Beat
      def run!
        started = Time.now.utc
        result = { rows_in: 0, rows_upserted: 0, error: nil }

        begin
          result[:rows_upserted] = compute(hall_slug, started)
          Muni::Store.bump_seen(self.class.slug, started)
          Muni::Store.mark_checked(self.class.slug, started, changed: result[:rows_upserted].positive?)
        rescue StandardError => e
          result[:error] = e
          Muni::Logger.instance.error("Beat #{self.class.slug} failed: #{e.class}: #{e.message}")
        ensure
          Muni::Store.log_beat_run(
            slug:          self.class.slug,
            started_at:    started,
            ended_at:      Time.now.utc,
            rows_in:       result[:rows_in],
            rows_upserted: result[:rows_upserted],
            error:         result[:error]
          )
        end

        result
      end

      private

      def hall_slug
        self.class.slug.split('/', 2).first
      end
    end

    class HallAnalytics < HallComputation
      private

      def compute(hall, started)
        Muni::Analytics.compute!(hall: hall, now: started)
        8
      end
    end

    class HallDigest < HallComputation
      private

      def compute(hall, started)
        Muni::Analytics.compute_digest!(hall: hall, now: started)
      end
    end

    class BostonAnalytics < HallAnalytics
      beat 'boston/analytics',
           source: -> { Muni::Analytics::NullSource }, every: '6h', mode: :full
    end

    class BostonDigest < HallDigest
      beat 'boston/digest',
           source: -> { Muni::Analytics::NullSource }, every: '6h', mode: :full
    end
  end
end
