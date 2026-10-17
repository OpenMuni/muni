require 'json'
require 'time'
require 'muni/analytics/support'

module Muni
  module Analytics
    # Cached, resident-facing daily civic briefing. Ruby owns facts, ranking,
    # links, visuals, validation, and fallbacks; the model may only edit copy.
    class CivicDigest # rubocop:disable Metrics/ClassLength
      KIND = 'civic_digest'.freeze
      TITLE = 'Digest'.freeze
      MAX_TITLE = 60
      MAX_SUMMARY = 220
      MAX_SOURCE_NOTE = 90
      MAX_FOOTNOTE = 160
      MAX_CARDS = 9
      VALID_TONES = %w[blue green amber rose neutral].freeze
      DIGEST_SOURCES = %w[
        cambridge/city_news
        cambridge/city_calendar
        cambridge/primegov_meetings
        cambridge/meetings
        cambridge/cambridge_life
        cambridge/cambridge_day
        cambridge/construction_highlights
        cambridge/city_construction_projects
        cambridge/practical_services
      ].freeze
      SECTION_LABELS = {
        'city_today'           => 'Today',
        'civic_decisions'      => 'Civic Decisions',
        'around_town'          => 'Around Town',
        'street_level_impacts' => 'Street-Level Impacts',
        'practical_reminders'  => 'Practical Reminders',
        'data_signals'         => 'Data Signals'
      }.freeze
      SECTION_ORDER = SECTION_LABELS.keys.freeze
      SECTION_QUOTAS = {
        'city_today'           => 3,
        'civic_decisions'      => 2,
        'around_town'          => 2,
        'street_level_impacts' => 2,
        'practical_reminders'  => 2,
        'data_signals'         => 1
      }.freeze
      DATA_SIGNAL_IDS = %w[311_volume_anomalies police_log_volume_anomalies safety_anomalies].freeze

      class << self
        def compute(hall:, now: Time.now.utc, client: nil)
          generated_at = Support.time_value(now) || Time.now.utc
          context = source_payload(hall: hall, now: generated_at)
          base_cards = deterministic_cards(context)
          return warming_payload(hall: hall, now: generated_at) if base_cards.empty?

          authored = authored_payload(client, context, base_cards)
          cards = merge_authored_cards(base_cards, authored)

          {
            'schema_version'   => 2,
            'status'           => 'ready',
            'title'            => TITLE,
            'edition_label'    => edition_label(context, generated_at),
            'edition_date'     => generated_at.utc.strftime('%Y-%m-%d'),
            'generated_at'     => Support.iso_time(generated_at),
            'source_max_at'    => context['source_max_at'],
            'source_freshness' => context['source_freshness'],
            'sections'         => sections_for(cards),
            'cards'            => cards,
            'footnotes'        => footnotes(context, authored)
          }
        rescue StandardError => e
          Muni::Logger.instance.warn("Civic digest skipped: #{e.class}: #{e.message}")
          nil
        end

        def source_payload(hall:, now: Time.now.utc)
          generated_at = Support.time_value(now) || Time.now.utc
          dashboard = Muni::Dashboard.snapshot(hall: hall)
          analytics = without_old_digest(hash_field(dashboard, :analytics))
          widgets = hash_field(dashboard, :widgets)
          signals = array_field(dashboard, :signals)
          sources = array_field(dashboard, :sources)
          source_items = digest_source_items(hall: hall, now: generated_at) +
                         meeting_digest_items(hall: hall, now: generated_at)
          ranked = rank_digest_items(source_items, generated_at)
          data_signals = data_signal_candidates(signals)

          {
            'hall'              => hall,
            'generated_at'      => Support.iso_time(generated_at),
            'source_max_at'     => latest_source_time(analytics, widgets, signals, sources, source_items),
            'source_freshness'  => digest_source_freshness(hall, now: generated_at),
            'source_items'      => source_items,
            'ranked_candidates' => ranked,
            'data_signals'      => data_signals,
            'signals'           => signals,
            'analytics'         => analytics,
            'widgets'           => widgets,
            'sources'           => sources
          }
        end

        def warming_payload(hall:, now: Time.now.utc)
          generated_at = Support.time_value(now) || Time.now.utc
          {
            'schema_version'   => 2,
            'status'           => 'warming',
            'title'            => TITLE,
            'edition_label'    => edition_label({ 'hall' => hall }, generated_at),
            'edition_date'     => generated_at.utc.strftime('%Y-%m-%d'),
            'generated_at'     => Support.iso_time(generated_at),
            'source_max_at'    => nil,
            'source_freshness' => {},
            'sections'         => [],
            'cards'            => [],
            'footnotes'        => ["Digest is warming from public #{hall_name(hall)} sources."]
          }
        end

        private

        def deterministic_cards(context)
          source_cards = selected_source_cards(context)
          return [] if source_cards.empty?

          cards = source_cards + data_signal_cards(context, start_priority: source_cards.length + 1)
          cards.sort_by { |card| [card['priority'].to_i, card['id']] }.first(MAX_CARDS)
        end

        def selected_source_cards(context)
          ranked = Array(context['ranked_candidates'])
          selected = select_ranked_items(ranked)
          selected.each_with_index.map { |item, index| source_item_card(context, item, index + 1) }
        end

        def select_ranked_items(ranked)
          selected = []
          used = {}
          SECTION_ORDER.each do |section|
            next if section == 'data_signals'

            section_items = ranked.select { |item| item['section_key'] == section }
            section_items.first(SECTION_QUOTAS.fetch(section, 1)).each do |item|
              next if used[item['id']]

              selected << item
              used[item['id']] = true
            end
          end

          ranked.each do |item|
            break if selected.length >= MAX_CARDS - 1
            next if used[item['id']]

            selected << item
            used[item['id']] = true
          end
          selected.first(MAX_CARDS - 1)
        end

        def digest_source_items(hall:, now:)
          return [] unless Muni::Store.db.table_exists?(:digest_items)

          lower_bound = now - (45 * 86_400)
          upper_bound = now + (30 * 86_400)
          Muni::Store.query(Muni::Records::DigestItem, hall: hall, limit: 500).filter_map do |record|
            normalize_digest_item(record.to_h, lower_bound, upper_bound)
          end
        rescue Sequel::DatabaseError
          []
        end

        # Recent, AI-summarized Granicus meetings, shaped like normalized digest
        # items so they compete within the civic_decisions quota. The Meeting
        # table is separate from digest_items, so this never touches existing
        # cards — meetings simply join the ranked candidate pool.
        def meeting_digest_items(hall:, now:)
          return [] unless Muni::Store.db.table_exists?(:meetings)

          lower_bound = now - (45 * 86_400)
          upper_bound = now + (7 * 86_400)
          Muni::Store.query(Muni::Records::Meeting, hall: hall, limit: 60).filter_map do |row|
            next if row.ai_summary.to_s.strip.empty?

            time = Support.time_value(row.meeting_at)
            next if time.nil? || time < lower_bound || time > upper_bound

            meeting_candidate(row, time, hall)
          end
        rescue Sequel::DatabaseError
          []
        end

        def meeting_candidate(row, time, hall)
          name = hall_name(hall)
          {
            'id'           => row.external_id,
            'external_id'  => row.external_id,
            'source_slug'  => "#{hall}/meetings",
            'source_name'  => "#{name} Meetings",
            'source_label' => row.body || "#{name} Meeting",
            'source_type'  => 'official_record',
            'item_type'    => 'public_meeting',
            'section_key'  => 'civic_decisions',
            'title'        => row.title,
            'summary'      => row.ai_summary,
            'category'     => 'public meetings',
            'url'          => row.video_url || row.agenda_url || row.source_url,
            'published_at' => Support.iso_time(time),
            'primary_time' => Support.iso_time(time),
            'tags'         => Array(row.key_topics),
            'confidence'   => 0.95,
            'dedupe_key'   => "meeting:#{row.external_id}",
            'metadata'     => {}
          }
        end

        def normalize_digest_item(attrs, lower_bound, upper_bound)
          item = stringify_keys(attrs)
          primary_time = digest_item_time(item)
          return nil if primary_time && primary_time < lower_bound
          return nil if primary_time && primary_time > upper_bound
          return nil if text_value(item, :title).nil?

          item['primary_time'] = Support.iso_time(primary_time) if primary_time
          item['source_type'] ||= 'official_record'
          item['section_key'] = normalize_section(text_value(item, :section_hint), item)
          item['source_label'] = text_value(item, :source_name) || source_label(text_value(item, :source_slug))
          item['id'] = text_value(item, :external_id)
          item['tags'] = Array(item['tags'])
          item['metadata'] = item['metadata'].is_a?(Hash) ? item['metadata'] : {}
          item
        end

        def rank_digest_items(items, now)
          best_by_key = {}
          items.each do |item|
            key = text_value(item, :dedupe_key) || text_value(item, :url) || text_value(item, :id)
            scored = item.merge(
              'score'       => digest_score(item, now),
              'section_key' => normalize_section(text_value(item, :section_key), item)
            )
            previous = best_by_key[key]
            best_by_key[key] = scored if previous.nil? || scored['score'] > previous['score']
          end

          best_by_key.values.sort_by { |item| [-item['score'], section_index(item['section_key']), item['title'].to_s] }
                            .map { |item| ranked_candidate(item) }
        end

        def ranked_candidate(item)
          item.slice(
            'id', 'external_id', 'source_slug', 'source_label', 'source_name', 'source_type', 'item_type',
            'section_key', 'title', 'summary', 'category', 'url', 'published_at', 'event_start_at',
            'event_end_at', 'updated_at', 'fetched_at', 'primary_time', 'location_name', 'neighborhood',
            'tags', 'confidence', 'dedupe_key', 'metadata', 'score'
          )
        end

        def digest_score(item, now)
          primary_time = Support.time_value(item['primary_time']) || digest_item_time(item)
          confidence = numeric(item['confidence']) || (item['source_type'].to_s == 'press_report' ? 0.72 : 0.9)
          recency = recency_score(primary_time, now)
          impact = impact_score(item)
          action = actionability_score(item)
          locality = text_value(item, :location_name) || text_value(item, :neighborhood) ? 10 : 6
          novelty = novelty_score(item, now)
          ((confidence * 15) + recency + impact + action + locality + novelty).round(2)
        end

        def recency_score(time, now)
          return 8 unless time

          days = (time - now) / 86_400.0
          return 20 if days.between?(-1, 1)
          return 17 if days.positive? && days <= 7
          return 15 if days.negative? && days >= -3
          return 10 if days.negative? && days >= -14

          5
        end

        def impact_score(item)
          category = [item['category'], item['item_type'], item['title'], item['summary'],
                      item['tags']].flatten.join(' ')
          return 25 if category.match?(/public comment|agenda|meeting|council|committee|commission/i)
          return 23 if category.match?(/construction|street|closure|detour|utility/i)
          return 22 if category.match?(/trash|recycling|street cleaning|collection|alert|reminder/i)
          return 18 if item['source_type'].to_s == 'official_record'
          return 12 if item['source_type'].to_s == 'press_report'

          14
        end

        def actionability_score(item)
          text = [item['title'], item['summary'], item['category'], item['tags']].flatten.join(' ')
          return 20 if text.match?(/deadline|public comment|sign up|register|rescheduled|closure|detour/i)
          return 16 if item['event_start_at'] || text.match?(/meeting|event|collection|street cleaning/i)
          return 10 if text.match?(/program|service|notice|update/i)

          6
        end

        def novelty_score(item, now)
          last_digest = Support.time_value(item['last_digest_at'])
          return 10 unless last_digest
          return -20 if last_digest > now - (3 * 86_400)

          4
        end

        def source_item_card(context, item, priority)
          section_key = normalize_section(item['section_key'], item)
          source_type = text_value(item, :source_type) || 'official_record'
          source_label = text_value(item, :source_label) || text_value(item, :source_name) || 'Source'
          card(
            id:          "source-#{item['id']}",
            section:     if section_key == 'city_today'
                           "Today in #{hall_name(context['hall'])}"
                         else
                           SECTION_LABELS.fetch(section_key, 'Today')
                         end,
            category:    text_value(item, :category) || text_value(item, :item_type) || 'civic update',
            tone:        tone_for_item(item),
            priority:    priority * 10,
            title:       item['title'],
            summary:     deterministic_summary(item),
            metric:      metric(source_badge(source_type), date_or_type_label(item), location_label(item)),
            visual:      source_visual(item, source_label, source_type),
            href:        item['url'],
            source_note: source_note(source_label, source_type)
          ).merge(
            'section_key'     => section_key,
            'source_type'     => source_type,
            'sources'         => [{
              'name'         => source_label,
              'type'         => source_type,
              'url'          => item['url'],
              'published_at' => item['published_at']
            }.compact],
            'published_at'    => item['published_at'],
            'event_start_at'  => item['event_start_at'],
            'event_end_at'    => item['event_end_at'],
            'location_name'   => item['location_name'],
            'tags'            => item['tags'],
            'confidence'      => item['confidence'],
            'freshness_label' => freshness_label(item)
          )
        end

        def deterministic_summary(item)
          summary = text_value(item, :summary)
          return summary if summary

          type_label = item['source_type'].to_s == 'press_report' ? 'Press report' : 'Official listing'
          "#{type_label} from #{text_value(item, :source_label) || 'an official city source'}."
        end

        def data_signal_cards(context, start_priority:)
          signals = data_signal_candidates(context['signals']).first(SECTION_QUOTAS.fetch('data_signals'))
          signals.each_with_index.map do |signal, index|
            data_signal_card(context, signal, start_priority + index)
          end
        end

        def data_signal_candidates(signals)
          selected = Array(signals).select do |signal|
            DATA_SIGNAL_IDS.include?(text_value(signal, :id)) && text_value(signal, :status) == 'watch'
          end
          selected.sort_by { |signal| [signal_severity_rank(signal), text_value(signal, :id)] }
        end

        def signal_severity_rank(signal)
          case text_value(signal, :tone)
          when 'rose' then 0
          when 'amber' then 1
          else 2
          end
        end

        def data_signal_card(context, signal, priority)
          id = text_value(signal, :id)
          title = text_value(signal, :headline) || text_value(signal, :title) || 'Data signal'
          summary = data_signal_summary(signal)
          category = text_value(signal, :category) || 'service_requests'
          card(
            id:          "data-signal-#{id}",
            section:     SECTION_LABELS.fetch('data_signals'),
            category:    category,
            tone:        text_value(signal, :tone) || 'amber',
            priority:    priority * 10,
            title:       title,
            summary:     summary,
            metric:      metric(text_value(signal, :metric) || 'WATCH', text_value(signal, :metric_label) || 'signal',
                                text_value(signal, :context)),
            visual:      { 'type' => 'delta_badge', 'value' => text_value(signal, :metric) || 'WATCH',
                           'label' => text_value(signal, :metric_label) || 'data signal',
                           'direction' => text_value(signal, :direction) || 'steady' },
            href:        category_href(context, category, text_value(signal, :time_range)),
            source_note: 'Trend/data signal from cached city records.'
          ).merge(
            'section_key' => 'data_signals',
            'source_type' => 'trend_data_signal',
            'sources'     => [{
              'name' => 'Muni Trends',
              'type' => 'trend_data_signal',
              'url'  => category_href(context, category, text_value(signal, :time_range))
            }]
          )
        end

        def data_signal_summary(signal)
          id = text_value(signal, :id)
          detail = text_value(signal, :detail) || 'A cached city data signal is above its normal range.'
          if id == 'police_log_volume_anomalies'
            return "#{detail} Police-log signals distinguish incident dates from publication catch-up."
          end
          return "#{detail} Safety data reflects reported activity only, not resident risk." if id == 'safety_anomalies'

          detail
        end

        def legacy_metric_cards(context)
          [
            service_request_card(context),
            safety_card(context),
            crash_risk_card(context),
            permits_card(context),
            mobility_card(context),
            trees_card(context)
          ].compact.sort_by { |card| [card['priority'].to_i, card['id']] }
        end

        def digest_source_freshness(hall, now:)
          digest_sources(hall).each_with_object({}) do |slug, out|
            beat = Muni::Registry.beat(slug)
            latest_run = Muni::Store.latest_beat_run(slug)
            latest_success = Muni::Store.latest_beat_run(slug, successful: true)
            cadence_seconds = beat&.every_seconds
            last_run_at = Support.time_value(latest_run&.[](:ended_at) || latest_run&.[](:started_at))
            last_success_at = Support.time_value(latest_success&.[](:ended_at) || latest_success&.[](:started_at))
            out[slug] = {
              'cadence'         => beat&.every,
              'cadence_seconds' => cadence_seconds,
              'last_run_at'     => Support.iso_time(last_run_at),
              'last_success_at' => Support.iso_time(last_success_at),
              'last_seen_at'    => Support.iso_time(Muni::Store.last_seen(slug)),
              'next_run_after'  => Support.iso_time(next_run_after(last_run_at, cadence_seconds)),
              'last_error'      => text_value(latest_run, :error),
              'status'          => source_run_status(latest_run, last_success_at, cadence_seconds, now)
            }.compact
          end
        rescue StandardError
          {}
        end

        def next_run_after(last_run_at, cadence_seconds)
          return nil unless last_run_at && cadence_seconds

          last_run_at + cadence_seconds
        end

        def source_run_status(latest_run, last_success_at, cadence_seconds, now)
          return 'failing' if text_value(latest_run, :error)
          return 'warming' unless last_success_at
          return 'ready' unless cadence_seconds

          anchor = Support.time_value(now) || Time.now.utc
          anchor - last_success_at > (cadence_seconds * 2) ? 'stale' : 'ready'
        end

        def sections_for(cards)
          grouped_cards = cards.group_by do |card|
            card['section_key'] || normalize_section(card['section'], card)
          end
          sections = grouped_cards.map do |key, rows|
            { 'key' => key, 'label' => SECTION_LABELS[key] || key.to_s, 'count' => rows.length }
          end
          sections.sort_by { |section| section_index(section['key']) }
        end

        def normalize_section(value, item = {})
          key = value.to_s.strip.downcase.tr(' ', '_').tr('-', '_')
          return key if SECTION_LABELS.key?(key)

          text = [item['title'], item['summary'], item['category'], item['item_type'],
                  item['tags']].flatten.compact.join(' ')
          return 'street_level_impacts' if text.match?(/construction|street|closure|detour|utility|sidewalk/i)
          return 'civic_decisions' if text.match?(/meeting|agenda|public comment|council|committee|commission/i)
          return 'practical_reminders' if text.match?(/trash|recycling|street cleaning|collection|alert|reminder/i)
          return 'around_town' if text.match?(/library|program|class|workshop|press|cambridge life/i)

          'city_today'
        end

        def section_index(key)
          SECTION_ORDER.index(key.to_s) || SECTION_ORDER.length
        end

        def source_label(slug)
          slug.to_s.split('/').last.tr('_', ' ').split.map(&:capitalize).join(' ')
        end

        def hall_name(hall)
          Muni::Hall.find(hall)&.name&.sub(/,\s*MA\z/, '') || hall.to_s.capitalize
        end

        def digest_sources(hall)
          declared = Muni::Registry.sources.values.filter_map do |source|
            source.slug if source.hall == hall.to_s && source.digest_role
          end
          legacy = hall.to_s == 'cambridge' ? DIGEST_SOURCES : []
          (declared + legacy).uniq
        end

        def source_badge(source_type)
          case source_type.to_s
          when 'press_report' then 'Press'
          when 'event_listing' then 'Event'
          when 'trend_data_signal' then 'Trend'
          else 'Official'
          end
        end

        def source_note(source_label, source_type)
          type = case source_type.to_s
                 when 'press_report' then 'press report'
                 when 'event_listing' then 'event listing'
                 when 'trend_data_signal' then 'trend/data signal'
                 else 'official record'
                 end
          "#{source_label}: #{type}."
        end

        def date_or_type_label(item)
          time = Support.time_value(item['event_start_at'] || item['published_at'] || item['updated_at'])
          return date_label(time) if time

          item['item_type'].to_s.tr('_', ' ')
        end

        def location_label(item)
          text_value(item, :location_name) || text_value(item, :neighborhood)
        end

        def freshness_label(item)
          date_or_type_label(item)
        end

        def source_visual(item, source_label, source_type)
          {
            'type'        => 'source_badge',
            'source'      => source_label,
            'source_type' => source_type,
            'date'        => item['event_start_at'] || item['published_at'] || item['updated_at'],
            'location'    => item['location_name'],
            'score'       => item['score']
          }.compact
        end

        def tone_for_item(item)
          text = [item['category'], item['item_type'], item['title'], item['summary'], item['tags']].flatten.join(' ')
          return 'amber' if text.match?(/deadline|public comment|rescheduled|closure|detour|construction/i)
          return 'blue' if text.match?(/meeting|council|committee|commission|housing|program/i)
          return 'green' if text.match?(/park|tree|open space|library|community|environment/i)
          return 'neutral' if item['source_type'].to_s == 'press_report'

          'blue'
        end

        def digest_item_time(item)
          %w[event_start_at published_at updated_at fetched_at last_seen_at collected_at].filter_map do |key|
            Support.time_value(item[key])
          end.first
        end

        def stringify_keys(hash)
          hash.each_with_object({}) { |(key, value), out| out[key.to_s] = jsonish_value(value) }
        end

        def jsonish_value(value)
          return Support.iso_time(value) if value.respond_to?(:utc)

          value
        end

        def service_request_card(context) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          widget = context.dig('widgets', :service_requests) || context.dig('widgets', 'service_requests') || {}
          analytics = context.dig('analytics', :service_requests) || context.dig('analytics', 'service_requests') || {}
          signal = signal(context, '311_volume_anomalies')
          anomalies = Array(context.dig('analytics', :service_request_anomalies, 'anomalies') ||
                            context.dig('analytics', 'service_request_anomalies', 'anomalies'))
          opened = number(widget_value(widget, :opened_last_7d))
          open_cases = number(widget_value(widget, :open_cases))
          typical = days_label(widget_value(analytics, :median_days))
          trend = Array(widget_value(widget, :opened_trend))
          top = anomalies.first || {}
          title = text_value(signal, :headline) || '311 activity'
          summary = if signal && text_value(signal, :status) == 'watch'
                      typical_phrase = typical == 'n/a' ? '' : " Typical close time is #{typical}."
                      "#{title} is running above its normal range.#{typical_phrase}"
                    else
                      "#{opened} requests opened in the latest source-covered week; #{open_cases} remain open citywide."
                    end

          card(
            id:          '311-activity',
            section:     SECTION_LABELS.fetch('data_signals'),
            category:    'service_requests',
            tone:        text_value(signal, :tone) || 'amber',
            priority:    10,
            title:       title,
            summary:     summary,
            metric:      metric(opened, 'opened 7d', open_cases.positive? ? "#{open_cases} open" : nil),
            visual:      service_request_visual(trend, top),
            href:        category_href(context, 'service_requests', '30d'),
            source_note: 'Official 311 source-covered records.'
          ).merge('section_key' => 'data_signals', 'source_type' => 'trend_data_signal')
        end

        def safety_card(context)
          widget = context.dig('widgets', :safety) || context.dig('widgets', 'safety') || {}
          signal = signal(context, 'safety_anomalies')
          total = number(widget_value(widget, :crime_reports_30d)) +
                  number(widget_value(widget, :dispatch_calls_30d)) +
                  number(widget_value(widget, :recent_crashes_30d))
          title = if signal && text_value(signal, :status) == 'watch'
                    text_value(signal, :headline)
                  else
                    'Safety activity steady'
                  end
          detail = if signal && text_value(signal, :status) == 'watch'
                     'Recent safety activity is above its normal range in official logs.'
                   else
                     'No unusual spike is visible in the latest safety window.'
                   end

          card(
            id:          'safety-activity',
            section:     SECTION_LABELS.fetch('data_signals'),
            category:    'safety',
            tone:        text_value(signal, :tone) || 'green',
            priority:    20,
            title:       title,
            summary:     "#{detail} Interpret police, dispatch, and crash records as reported activity, " \
                         'not resident risk.',
            metric:      metric(total, 'records 30d', nil),
            visual:      stat_strip([
                                      ['crime', widget_value(widget, :crime_reports_30d)],
                                      ['dispatch', widget_value(widget, :dispatch_calls_30d)],
                                      ['crashes', widget_value(widget, :recent_crashes_30d)]
                                    ]),
            href:        category_href(context, 'safety', 'latest'),
            source_note: 'Police, dispatch, crime, and recent crash logs.'
          ).merge('section_key' => 'data_signals', 'source_type' => 'trend_data_signal')
        end

        def crash_risk_card(context)
          model = context.dig('analytics', :crash_risks) || context.dig('analytics', 'crash_risks') || {}
          locations = Array(widget_value(model, :locations))
          return nil if warming?(model) || locations.empty?

          top = locations.first
          label = text_value(top, :label) || 'Mapped crash-risk cluster'
          score = number(widget_value(top, :score))
          crashes = number(widget_value(top, :crash_count))
          summary = "#{label} is the top ranked crash-risk location in the current model. Rankings are weighted " \
                    'by recency and vulnerable road-user involvement.'

          card(
            id:          'crash-risk',
            section:     SECTION_LABELS.fetch('data_signals'),
            category:    'crashes',
            tone:        'rose',
            priority:    30,
            title:       label,
            summary:     summary,
            metric:      metric(risk_label(score), 'risk', "#{crashes} #{plural(crashes, 'crash', 'crashes')}"),
            visual:      rank_bar(locations.first(4), value_key: :score),
            href:        category_href(context, 'crashes', '90d'),
            source_note: 'Vision Zero crash history model.'
          ).merge('section_key' => 'data_signals', 'source_type' => 'trend_data_signal')
        end

        def permits_card(context)
          widget = context.dig('widgets', :permits) || context.dig('widgets', 'permits') || {}
          analytics = context.dig('analytics', :permits) || context.dig('analytics', 'permits') || {}
          count = number(widget_value(widget, :permits_last_30d))
          typical = days_label(widget_value(analytics, :median_days))
          summary = "#{count} permits were issued in the latest 30-day source window. Typical issue time is " \
                    "#{typical} based on cached history."

          card(
            id:          'permit-activity',
            section:     SECTION_LABELS.fetch('data_signals'),
            category:    'permits',
            tone:        'blue',
            priority:    40,
            title:       'Permit activity',
            summary:     summary,
            metric:      metric(count, 'issued 30d', typical == 'n/a' ? nil : "#{typical} typical"),
            visual:      sparkline(widget_value(widget, :trend), 'blue'),
            href:        category_href(context, 'permits', '30d'),
            source_note: 'Official building permit records.'
          ).merge('section_key' => 'data_signals', 'source_type' => 'trend_data_signal')
        end

        def mobility_card(context)
          traffic = context.dig('widgets', :traffic_volume) || context.dig('widgets', 'traffic_volume') || {}
          bikes = context.dig('widgets', :bicycle_counts) || context.dig('widgets', 'bicycle_counts') || {}
          pedestrians = context.dig('widgets', :pedestrian_counts) || context.dig('widgets', 'pedestrian_counts') || {}
          totals = [
            ['vehicles', widget_value(traffic, :total_30d)],
            ['bikes', widget_value(bikes, :total_30d)],
            ['walks', widget_value(pedestrians, :total_30d)]
          ]
          total = totals.sum { |_, value| number(value) }
          return nil unless total.positive?

          label = text_value(traffic, :label) || text_value(bikes, :label) || text_value(pedestrians, :label)
          card(
            id:          'mobility-counts',
            section:     SECTION_LABELS.fetch('data_signals'),
            category:    'traffic_volume',
            tone:        'neutral',
            priority:    50,
            title:       label || 'Mobility counts',
            summary:     'Representative mobility counters show source-covered movement patterns across vehicles, ' \
                         'bikes, and pedestrians.',
            metric:      metric(total, 'counted 30d', nil),
            visual:      stat_strip(totals),
            href:        category_href(context, 'traffic_volume', '30d'),
            source_note: 'Representative city counter feeds.'
          ).merge('section_key' => 'data_signals', 'source_type' => 'trend_data_signal')
        end

        def trees_card(context)
          widget = context.dig('widgets', :trees) || context.dig('widgets', 'trees') || {}
          total = number(widget_value(widget, :current_tree_records))
          return nil unless total.positive?

          species = number(widget_value(widget, :species_count))
          card(
            id:          'urban-forest',
            section:     SECTION_LABELS.fetch('data_signals'),
            category:    'trees',
            tone:        'green',
            priority:    60,
            title:       'Urban forest inventory',
            summary:     "#{total} current street-tree records are in the inventory, spanning #{species} " \
                         'common species labels.',
            metric:      metric(total, 'current trees', "#{species} species"),
            visual:      rank_bar(Array(widget_value(widget, :by_species)).first(4), value_key: :count),
            href:        category_href(context, 'trees', nil),
            source_note: 'Official street tree inventory.'
          ).merge('section_key' => 'data_signals', 'source_type' => 'trend_data_signal')
        end

        def authored_payload(client, context, cards)
          client ||= Muni::AnthropicClient.new if defined?(Muni::AnthropicClient)
          return {} unless client&.configured?

          parse_json_object(generate_text(client, authoring_context(context, cards))) || {}
        rescue StandardError => e
          Muni::Logger.instance.warn("Civic digest authoring fallback: #{e.class}: #{e.message}")
          {}
        end

        def authoring_context(context, cards)
          {
            'hall'          => context['hall'],
            'generated_at'  => context['generated_at'],
            'source_max_at' => context['source_max_at'],
            'rules'         => {
              'title_max_chars'       => MAX_TITLE,
              'summary_max_chars'     => MAX_SUMMARY,
              'source_note_max_chars' => MAX_SOURCE_NOTE
            },
            'cards'         => cards.map do |card|
              card.slice('id', 'section', 'section_key', 'category', 'source_type', 'title', 'summary',
                         'source_note', 'sources', 'published_at', 'event_start_at', 'location_name')
            end
          }
        end

        def generate_text(client, payload)
          text = +''
          client.stream(
            messages:   [{ role: 'user', content: JSON.generate(payload) }],
            system:     system_prompt(payload['hall']),
            max_tokens: 1_500
          ) do |event|
            text << event[:text].to_s if event[:type].to_s == 'text_delta'
          end
          text
        end

        def system_prompt(hall)
          name = hall_name(hall)
          <<~TEXT
            You write the Muni.fyi Digest for #{name} residents.
            Return only a single JSON object. Do not use markdown, HTML, code fences, emoji, or commentary.
            Use only the provided JSON. Do not invent facts, metrics, locations, dates, URLs, or sources.
            Edit only concise resident-facing copy for existing card ids. Do not add, remove, or reorder cards.
            Keep summaries calm, useful, cautious, and 1-2 short sentences.
            Make source type clear when useful: official record, press report, event listing, trend/data signal, or model inference.
            For safety data, describe reported activity only and never imply resident risk or individual blame.
            For press sources, preserve attribution and do not reproduce article bodies.
            Return this shape: {"cards":[{"id":"existing id","title":"short title","summary":"short summary","source_note":"optional short note"}],"footnotes":["optional short note"]}.
          TEXT
        end

        def parse_json_object(text)
          raw = text.to_s.strip
          raw = raw.sub(/\A```(?:json)?\s*/i, '').sub(/\s*```\z/, '').strip
          parsed = JSON.parse(raw)
          parsed.is_a?(Hash) ? parsed : nil
        rescue JSON::ParserError
          nil
        end

        def merge_authored_cards(base_cards, authored)
          authored_by_id = Array(authored['cards']).each_with_object({}) do |card, out|
            next unless card.is_a?(Hash)

            out[card['id'].to_s] = card
          end

          base_cards.map do |base|
            authored_card = authored_by_id[base['id']] || {}
            merged = base.dup
            merged['title'] = clean_text(authored_card['title'], MAX_TITLE) || base['title']
            merged['summary'] = clean_text(authored_card['summary'], MAX_SUMMARY) || base['summary']
            merged['source_note'] = clean_text(authored_card['source_note'], MAX_SOURCE_NOTE) || base['source_note']
            merged
          end
        end

        def footnotes(context, authored)
          generated = context['source_max_at'] ? "Source data through #{date_label(context['source_max_at'])}." : nil
          press = Array(context['source_items']).any? { |item| item['source_type'] == 'press_report' }
          safety = Array(context['data_signals']).any? { |signal| text_value(signal, :id) == 'safety_anomalies' }
          notes = Array(authored['footnotes']).filter_map { |note| clean_text(note, MAX_FOOTNOTE) }
          base = [generated, ('Press cards use headline and excerpt metadata only.' if press),
                  ('Safety data reflects reported incidents only.' if safety)]
          ([*base, *notes] - [nil]).uniq.first(3)
        end

        def card(id:, section:, category:, tone:, priority:, title:, summary:, metric:, visual:, href:, source_note:)
          {
            'id'          => id,
            'section'     => clean_text(section, 32) || 'City',
            'category'    => category.to_s,
            'tone'        => VALID_TONES.include?(tone.to_s) ? tone.to_s : 'neutral',
            'priority'    => priority.to_i,
            'title'       => clean_text(title, MAX_TITLE) || 'City update',
            'summary'     => clean_text(summary, MAX_SUMMARY) || 'No concise summary is available yet.',
            'metric'      => metric,
            'visual'      => visual,
            'href'        => href.to_s,
            'source_note' => clean_text(source_note, MAX_SOURCE_NOTE) || 'Official city source record.'
          }
        end

        def metric(value, label, sublabel)
          {
            'value'    => value.to_s,
            'label'    => label.to_s,
            'sublabel' => sublabel.to_s
          }.reject { |_, text| text.empty? }
        end

        def service_request_visual(trend, anomaly)
          ratio = numeric(widget_value(anomaly, :ratio))
          badge = if ratio && ratio > 1
                    {
                      'value'     => "+#{((ratio - 1) * 100).round}%",
                      'label'     => 'vs typical',
                      'direction' => 'up'
                    }
                  end
          visual = sparkline(trend, 'amber')
          badge ? visual.merge('badge' => badge) : visual
        end

        def sparkline(points, tone)
          {
            'type'   => 'sparkline',
            'tone'   => VALID_TONES.include?(tone.to_s) ? tone.to_s : 'neutral',
            'points' => Array(points).first(30).map do |point|
              {
                'date'  => text_value(point, :date),
                'label' => text_value(point, :label),
                'value' => number(widget_value(point, :value))
              }
            end
          }
        end

        def stat_strip(rows)
          {
            'type'  => 'stat_strip',
            'stats' => rows.map do |label, value|
              { 'label' => label.to_s, 'value' => number(value).to_s }
            end
          }
        end

        def rank_bar(rows, value_key:)
          items = Array(rows).map do |row|
            value = number(widget_value(row, value_key))
            {
              'label' => text_value(row, :label) || text_value(row, :name) || 'Unknown',
              'value' => value
            }
          end
          max = [items.map { |item| item['value'] }.max.to_i, 1].max
          {
            'type'  => 'rank_bar',
            'items' => items.map { |item| item.merge('share' => ((item['value'] / max.to_f) * 100).round) }
          }
        end

        def signal(context, id)
          Array(context['signals']).find { |entry| text_value(entry, :id) == id }
        end

        def category_href(context, category, time_range)
          params = ["hall=#{context['hall']}", "category=#{category}"]
          params << "time_range=#{time_range}" if time_range
          "/?#{params.join('&')}"
        end

        def edition_label(context, now)
          hall = Muni::Hall.find(context['hall'].to_s)&.name || context['hall'] || 'City'
          "#{hall} / #{date_label(now)}"
        end

        def latest_source_time(*values)
          times = values.flat_map { |value| collect_times(value) }
          times.compact.max&.iso8601
        end

        def collect_times(value)
          case value
          when Hash
            value.flat_map do |key, nested|
              key = key.to_s
              key.end_with?('_at') && key != 'generated_at' ? [Support.time_value(nested)] : collect_times(nested)
            end
          when Array
            value.flat_map { |nested| collect_times(nested) }
          else
            []
          end
        end

        def without_old_digest(analytics)
          analytics.reject { |key, _| key.to_s == 'civic_digest' }
        end

        def hash_field(hash, key)
          value = widget_value(hash, key)
          value.is_a?(Hash) ? value : {}
        end

        def array_field(hash, key)
          value = widget_value(hash, key)
          value.is_a?(Array) ? value : []
        end

        def widget_value(hash, key)
          return nil unless hash.respond_to?(:key?)

          [key, key.to_s, key.to_sym].uniq.each do |candidate|
            return hash[candidate] if hash.key?(candidate)
          end
          nil
        end

        def text_value(hash, key)
          value = widget_value(hash, key)
          text = value.to_s.strip
          text.empty? ? nil : text
        end

        def clean_text(value, max)
          text = value.to_s.encode('ASCII', invalid: :replace, undef: :replace, replace: '')
                      .gsub(/[<>`*_#]/, '')
                      .gsub(/\s+/, ' ')
                      .strip
          return nil if text.empty?
          return text if text.length <= max

          trimmed = text[0, max - 3].sub(/\s+\S*\z/, '').strip
          "#{trimmed.empty? ? text[0, max - 3] : trimmed}..."
        end

        def number(value)
          numeric(value)&.round || 0
        end

        def numeric(value)
          num = Float(value)
          num.finite? ? num : nil
        rescue ArgumentError, TypeError
          nil
        end

        def days_label(value)
          days = numeric(value)
          return 'n/a' unless days&.positive?
          return "#{(days * 24).round}h" if days < 1

          "#{days.round(1)}d"
        end

        def risk_label(score)
          score = score.to_i
          return 'HIGH' if score >= 67
          return 'MED' if score >= 34

          'LOW'
        end

        def warming?(model)
          text_value(model, :status).to_s == 'warming'
        end

        def plural(count, singular, plural)
          count.to_i == 1 ? singular : plural
        end

        def date_label(value)
          time = Support.time_value(value) || Time.now.utc
          time.utc.strftime('%b %-d')
        end
      end
    end
  end
end
