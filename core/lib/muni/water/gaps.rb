module Muni
  module Water
    # Recheck corrected local days and the newly monitored tail. Indexed nearest
    # observations preserve the identity of a long gap without rereading its history.
    class Gaps
      SELECTOR = %i[location_id parameter unit method segment].freeze

      def initialize(now:, publisher:)
        @now = now
        @publisher = publisher
      end

      def calculate(slug, dirty: nil)
        @slug = slug
        @definition = Catalog.definitions[slug.delete_prefix(PREFIX)]
        return unless @definition&.dig(:interval)

        @checkpoint = Storage.checkpoint(slug)
        @started = Water.time(@checkpoint['monitoring_started_at'])
        checked = Water.time(@checkpoint['last_success_at'])
        return unless @started && checked && @checkpoint['boating_season'] != false

        @deadline = [@now, checked].min - @definition[:grace]
        return if @deadline <= @started

        @previous = dirty && Water.time(Muni::Store.meta("water:gap_deadline:#{slug}"))
        @dirty = Array(dirty).map { |entry| Water.canonical(entry) }
        groups.each { |group| calculate_group(group) }
        Muni::Store.set_meta("water:gap_deadline:#{slug}", @deadline.iso8601)
      end

      private

      def groups
        cached = Storage.db[:water_daily_summaries].where(source_slug: @slug)
                        .select(:selector).distinct.select_map(:selector)
        unless cached.empty?
          return cached.map do |value|
            JSON.parse(value, symbolize_names: true).slice(*SELECTOR)
          end.uniq
        end

        Storage.evidence.where(source_slug: @slug).exclude(value: nil).select(*SELECTOR).distinct.all
      end

      def calculate_group(group)
        source = Storage.evidence.where(source_slug: @slug, location_id: group[:location_id],
                                        parameter: group[:parameter])
                        .exclude(value: nil).exclude(observed_at: nil)
        selected = source.where(group)
        last = Water.time(selected.max(:observed_at))
        return unless last

        first = Water.time(selected.min(:observed_at))
        @group_started = first > Water.time(source.min(:observed_at)) ? [@started, first].max : @started
        deadline = last < Water.time(source.max(:observed_at)) ? [@deadline, last].min : @deadline
        windows(group, deadline).each { |from, to| check_window(selected, group, from, to, deadline) }
        retire_gaps(group, deadline) if deadline < @deadline
      end

      def windows(group, deadline)
        ranges = @dirty.filter_map do |entry|
          next unless entry['selector'].transform_keys(&:to_sym).slice(*SELECTOR) == group

          Clock.bounds(Date.parse(entry['date']))
        end
        if !@previous || @previous < deadline
          ranges << [@previous ? @previous - @definition[:interval] : @group_started, deadline]
        end
        bounded = ranges.map { |from, to| [[from, @group_started].max, [to, deadline].min] }
                        .select { |from, to| from <= to }.sort_by(&:first)
        merge_windows(bounded)
      end

      def merge_windows(bounded)
        bounded.each_with_object([]) do |range, merged|
          if merged.last && range.first <= merged.last.last
            merged.last[1] = [merged.last.last, range.last].max
          else
            merged << range
          end
        end
      end

      def check_window(selected, group, from, to, deadline)
        interval = @definition[:interval]
        left = Water.time(selected.where { observed_at < from }.max(:observed_at)) || (@group_started - interval)
        right = Water.time(selected.where { observed_at > to }.min(:observed_at)) || (deadline + interval)
        times = selected.where(observed_at: from..to).order(:observed_at).select_map(:observed_at)
        active = ([left] + times + [right]).uniq.sort.each_cons(2).filter_map do |before, after|
          gap_start = [before + interval, @group_started].max
          gap_end = [after - interval, deadline].min
          next unless after - before > interval * 1.5 && gap_start <= gap_end && gap_start <= to && gap_end >= from

          publish_gap(group, gap_start, gap_end)
        end
        resolve_gaps(group, active, from, to)
      end

      def publish_gap(group, from, to)
        interval = @definition[:interval]
        key = "gap/#{@slug}/#{Water.hash(group)}/#{from.iso8601}"
        @publisher.publish(key, 'missing_observations', 'active', source_slug: @slug, selector: group,
          window: { start: from, end: to }, coverage: { expected_interval_seconds: interval,
            missing_intervals: ((to - from) / interval).floor + 1, allowance_seconds: @definition[:grace] },
          evidence: { checked_through: @checkpoint['last_success_at'] },
          method: 'Expected intervals since muni monitoring began, after the source lateness allowance.',
          explanation: 'Expected observations were absent from successful source checks.')
        key
      end

      def resolve_gaps(group, active, from, to)
        active_gaps(group).each do |row|
          next if active.include?(row[:signal_key])

          payload = JSON.parse(row[:payload], symbolize_names: true)
          next if Water.time(payload[:window][:start]) > to || Water.time(payload[:window][:end]) < from

          @publisher.publish(row[:signal_key], 'missing_observations', 'filled',
                             payload.merge(explanation: 'Later publications filled this previously observed gap.'))
        end
      end

      def retire_gaps(group, deadline)
        active_gaps(group).each do |row|
          payload = JSON.parse(row[:payload], symbolize_names: true)
          next unless Water.time(payload[:window][:start]) > deadline

          explanation = 'A newer source series replaced this deployment; no later intervals are expected.'
          @publisher.publish(row[:signal_key], 'missing_observations', 'resolved',
                             payload.merge(explanation: explanation))
        end
      end

      def active_gaps(group)
        prefix = "gap/#{@slug}/#{Water.hash(group)}/"
        Storage.db[:water_signals].where(kind: 'missing_observations', status: 'active')
               .where(Sequel.like(:signal_key, "#{prefix}%"))
      end
    end
  end
end
