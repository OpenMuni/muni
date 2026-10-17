require 'time'

module Muni
  # Single-threaded supervisor loop. Each beat is run in turn, then re-scheduled
  # by its cadence. Sleeps just long enough to hit the next due beat.
  class Scheduler
    MAINTENANCE_RETRY_SECONDS = 15 * 60

    def initialize(beats: nil, logger: Muni::Logger.instance, clock: -> { Time.now })
      now = clock.call
      ordered_beats = Muni::Beat.ordered(beats || Muni::Registry.beats.values)
      @beats = ordered_beats.each_with_index.map do |beat, index|
        Entry.new(beat, initial_next_run_at(beat, now, index))
      end
      @logger = logger
      @clock = clock
      @stop = false
      @running = []
      @runs = 0
    end

    Entry = Struct.new(:beat_class, :next_run_at)

    def stop!
      @stop = true
    end

    def tick_once
      previous = @runs
      old_yield = Thread.current[:muni_scheduler_yield]
      Thread.current[:muni_scheduler_yield] = -> { run_due }
      run_due
      water_maintenance
      store_maintenance
      @runs - previous
    ensure
      Thread.current[:muni_scheduler_yield] = old_yield
    end

    def run!
      install_signal_handlers
      @logger.info("Scheduler: running #{@beats.size} beats")
      until @stop
        sleep_for = next_sleep
        sleep(sleep_for) if sleep_for.positive?
        tick_once
      end
      @logger.info('Scheduler: stopped')
    end

    private

    def store_maintenance
      now = @clock.call
      return if @maintenance_retry_at && now < @maintenance_retry_at

      Muni::Store.perform_maintenance!(now: now)
      @maintenance_retry_at = nil
    rescue StandardError => e
      @maintenance_retry_at = @clock.call + MAINTENANCE_RETRY_SECONDS
      @logger.error("Store maintenance: #{e.class}: #{e.message}; retry after #{@maintenance_retry_at.utc.iso8601}")
    end

    def run_due
      @beats.each do |entry|
        next if @running.include?(entry) || entry.next_run_at > @clock.call

        run_entry(entry)
      end
    end

    def water_maintenance
      return unless defined?(Muni::Water::Calculations) && Muni::Water.enabled? && Muni::Water.processing_enabled?

      Muni::Water::DailySummaries.new(now: @clock.call).close_days
      Muni::Water::Calculations.new(now: @clock.call).drain(limit: 1)
    rescue StandardError => e
      @logger.error("Water calculation maintenance: #{e.class}: #{e.message}")
    end

    def initial_next_run_at(beat_class, now, index = 0)
      latest = Muni::Store.latest_beat_run(beat_class.slug)
      last_ended_at = time_value(latest&.[](:ended_at) || latest&.[](:started_at))
      return beat_class.schedule_policy.initial(now, last_ended_at) if beat_class.respond_to?(:schedule_policy)
      return now + (index * stagger_seconds) unless last_ended_at

      due_at = last_ended_at + beat_class.every_seconds
      [due_at, now].max
    rescue StandardError
      now
    end

    def stagger_seconds
      ENV.fetch('MUNI_BEAT_STAGGER_SECONDS', '30').to_i
    end

    def run_entry(entry)
      @running << entry
      @runs += 1
      previous_yield = Thread.current[:muni_scheduler_yield]
      previous_entry = Thread.current[:muni_scheduler_entry]
      Thread.current[:muni_scheduler_yield] = -> { run_due }
      Thread.current[:muni_scheduler_entry] = { source_slug: entry.beat_class.slug, due_at: entry.next_run_at }
      @logger.info("Beat run: #{entry.beat_class.slug}")
      result = entry.beat_class.new.run!
    rescue StandardError => e
      @logger.error("Beat #{entry.beat_class.slug} bubbled: #{e.class}: #{e.message}")
    ensure
      Thread.current[:muni_scheduler_yield] = previous_yield
      Thread.current[:muni_scheduler_entry] = previous_entry
      @running.delete(entry)
      entry.next_run_at = reschedule(entry, result)
    end

    def reschedule(entry, result)
      return result[:next_run_at] if result.is_a?(Hash) && result[:next_run_at]
      return entry.beat_class.schedule_policy.next_after(@clock.call) if entry.beat_class.respond_to?(:schedule_policy)

      @clock.call + entry.beat_class.every_seconds
    end

    def next_sleep
      return 0 if @beats.empty?

      delay = [@beats.map(&:next_run_at).min - @clock.call, 0].max
      defined?(Muni::Water) && Muni::Water.enabled? ? [delay, 30].min : delay
    end

    def time_value(value)
      return value if value.is_a?(Time)
      return nil if value.nil?

      Time.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def install_signal_handlers
      %w[INT TERM].each { |sig| trap(sig) { @stop = true } }
    end
  end
end
