require 'muni/helpers/normalize'

module Muni
  # Binds one Source to a schedule + writes results into Muni::Store.
  #
  #   class Muni::Beats::Cambridge311 < Muni::Beat
  #     beat 'cambridge/service_requests',
  #          source: Cambridge::ServiceRequests,
  #          every:  '5m',
  #          mode:   :incremental
  #   end
  class Beat
    class << self
      attr_reader :slug, :every, :mode, :limit, :cursor, :prune_stale

      # Accepts either a class or a lambda returning a class. The lambda form
      # lets a Beat reference a Source that lives outside the gem's autoload
      # path (e.g. anything under sources/).
      def beat(slug, source:, every:, mode: :incremental, limit: nil, cursor: nil, prune_stale: false)
        @slug = slug
        @source_thunk = source
        @every = every
        @mode = mode
        @limit = limit
        @cursor = cursor
        @prune_stale = prune_stale
        Muni::Registry.register_beat(self)
      end

      def source_class
        @source_thunk.respond_to?(:call) ? @source_thunk.call : @source_thunk
      end

      def every_seconds
        Muni::Helpers::Normalize.parse_cadence(@every)
      end

      def register_catalog_beats!
        Muni::Registry.sources.each_value do |source|
          next if source.cadence.to_s.empty? || Muni::Registry.beat(source.slug)

          inventory = source.inventory_mode == :replace
          Class.new(Muni::Beat).beat(
            source.slug,
            source:      source,
            every:       source.cadence,
            mode:        inventory ? :full : :incremental,
            prune_stale: inventory
          )
        end
      end

      def ordered(beats)
        beats.sort_by { |beat_class| [schedule_rank(beat_class.slug), beat_class.slug] }
      end

      def schedule_rank(slug)
        return 3 if slug.end_with?('/digest', '/meetings_summary')
        return 2 if slug.end_with?('/analytics', '/primegov_meeting_records')

        1
      end
    end

    def run!
      started = Time.now.utc
      result = { rows_in: 0, rows_upserted: 0, error: nil }

      begin
        result.merge!(pull_and_persist(started))
      rescue StandardError => e
        result[:error] = e
        Muni::Logger.instance.error("Beat #{self.class.slug} failed: #{e.class}: #{e.message}")
      ensure
        log_run(started, result)
      end

      result
    end

    private

    # Coordinates streaming, batching, cursoring, reconciliation, and retention
    # as one success boundary so partial collectors never prune inventory.
    # rubocop:disable Metrics/AbcSize
    def pull_and_persist(started)
      source = self.class.source_class.new
      slug = source.class.slug
      offset = offset_cursor(slug)
      limit = beat_limit
      since = self.class.mode == :incremental ? overlapped_since(Muni::Store.last_seen(slug)) : nil
      rows_in = 0
      rows_upserted = 0
      newest = nil
      batch = []
      source.each_record(**pull_args(since, limit, offset)) do |record|
        stamp_record!(record, started)
        batch << record
        rows_in += 1
        candidate = cursor_time(source, record)
        newest = candidate if candidate && (!newest || candidate > newest)
        if batch.length >= 750
          rows_upserted += Muni::Store.bulk_upsert(batch)
          batch.clear
        end
      end
      rows_upserted += Muni::Store.bulk_upsert(batch) unless batch.empty?

      complete = refresh_complete?(rows_in, limit)
      prune_stale_records(source, started) if prune_stale_refresh?(rows_in, complete)
      Muni::Store.enforce_source_retention(source.class, now: started)
      Muni::Store.bump_seen(slug, newest || started) if rows_in.positive?
      Muni::Store.mark_checked(slug, started, changed: rows_in.positive?)
      advance_offset_cursor(slug, offset, rows_in, limit) if self.class.cursor == :offset

      { rows_in: rows_in, rows_upserted: rows_upserted }
    end
    # rubocop:enable Metrics/AbcSize

    def prune_stale_refresh?(rows_in, complete)
      self.class.mode == :full && self.class.prune_stale && rows_in.positive? && complete
    end

    def refresh_complete?(rows_in, limit)
      limit.nil? || rows_in < limit
    end

    def prune_stale_records(source, started)
      klass = source.class.emits
      return unless klass.schema_def&.column_names&.include?(:last_seen_at)

      Muni::Store.delete_before(klass, :last_seen_at, started, hall: source.class.hall)
    end

    def log_run(started, result)
      Muni::Store.log_beat_run(
        slug:          self.class.slug,
        started_at:    started,
        ended_at:      Time.now.utc,
        rows_in:       result[:rows_in],
        rows_upserted: result[:rows_upserted],
        error:         result[:error]
      )
    end

    def overlapped_since(time)
      return nil unless time

      time - overlap_seconds
    end

    def overlap_seconds
      ENV.fetch('MUNI_BEAT_OVERLAP_SECONDS', '7200').to_i
    end

    def beat_limit
      env_value = ENV.fetch(beat_limit_env_key, nil) || ENV.fetch('MUNI_BEAT_LIMIT', nil)
      return env_value.to_i if env_value&.to_i&.positive?

      self.class.limit
    end

    def beat_limit_env_key
      "MUNI_BEAT_LIMIT_#{self.class.slug.upcase.gsub(/[^A-Z0-9]+/, '_')}"
    end

    def pull_args(since, limit, offset)
      args = {}
      args[:since] = since if since
      args[:limit] = limit if limit
      args[:offset] = offset if self.class.cursor == :offset
      args
    end

    def stamp_record!(record, time)
      record.collected_at = time if record.respond_to?(:collected_at=)
      record.last_seen_at = time if record.respond_to?(:last_seen_at=)
    end

    def cursor_time(source, record)
      return source.cursor_time(record) if source.respond_to?(:cursor_time)

      fallback_cursor_time(record)
    end

    def fallback_cursor_time(record)
      attrs = record.to_h
      %i[updated_at reported_at opened_at occurred_at issued_at applied_at observed_at starts_at
         collected_at].each do |key|
        value = attrs[key]
        return value if value
      end
      nil
    end

    def offset_cursor(slug)
      return nil unless self.class.cursor == :offset

      Muni::Store.meta(offset_cursor_key(slug)).to_i
    end

    def advance_offset_cursor(slug, offset, rows_in, limit)
      next_offset = if rows_in.zero? || (limit && rows_in < limit)
                      0
                    else
                      offset.to_i + rows_in
                    end
      Muni::Store.set_meta(offset_cursor_key(slug), next_offset)
    end

    def offset_cursor_key(slug)
      "cursor:offset:#{slug}"
    end
  end

  module Beats
  end
end
