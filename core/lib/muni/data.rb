require 'date'
require 'time'
require 'muni/data/meetings'

module Muni
  module Data
    class Error < StandardError; end
    class NotFound < Error; end

    QUERY_LIMIT = Muni::View::DEFAULT_QUERY_LIMIT

    class << self
      def halls
        Muni::Hall.all.select(&:public?).map(&:to_h)
      end

      def sources(hall: nil)
        slugs = Muni::Registry.sources.keys
        slugs = slugs.select { |slug| Muni::Registry.source(slug).applicable_to_hall?(hall) } if hall
        slugs.sort.map { |s| { slug: s } }
      end

      def categories(hall: nil)
        counts = hall ? Muni::Store.counts_by_source(hall: hall) : Muni::Store.counts_by_source
        cats = hall ? Muni::View.for_hall(hall) : Muni::View.all
        cats.map do |cat|
          primary = Muni::View.primary_source(cat.slug, hall) if hall
          row_count = hall ? Muni::View.category_row_count(cat.slug, hall, counts) : 0
          h = cat.to_h.transform_keys(&:to_s).transform_values { |v| v.is_a?(Symbol) ? v.to_s : v }
          h.merge(
            'slug'           => cat.slug.to_s,
            'primary_source' => primary,
            'source_slugs'   => hall ? Muni::View.sources_for(cat.slug, hall) : cat.source_slugs,
            'row_count'      => row_count,
            'collecting'     => false,
            'disabled'       => false,
            'empty_message'  => cat.empty_message
          )
        end
      end

      def dashboard(hall:)
        require_hall!(hall)
        Muni::Dashboard.snapshot(hall: hall)
      end

      def digest(hall:)
        require_hall!(hall)
        payload = Muni::Analytics.digest(hall: hall)
        payload = payload.merge('schema_version' => payload['schema_version'] || 2, 'title' => 'Digest')
        payload.delete('body')
        payload
      end

      def meetings(hall:, limit: 50)
        require_hall!(hall)
        lim = query_limit(limit)
        Meetings.call(hall: hall, limit: lim)
      end

      def prediction(type:, hall:, limit: 25, attrs: {})
        require_hall!(hall)
        case type.to_s
        when 'service_requests'
          Muni::Analytics.predict_service_request(hall: hall, attrs: attrs)
        when 'permits'
          Muni::Analytics.predict_permit(hall: hall, attrs: attrs)
        when 'crash_risks'
          Muni::Analytics.crash_risks(hall: hall, limit: prediction_limit(limit))
        when 'service_request_anomalies'
          Muni::Analytics.service_request_anomalies(hall: hall, limit: prediction_limit(limit))
        else
          raise NotFound, 'unknown prediction type'
        end
      end

      def parking_check(hall:, lat:, lon:, arrive_at: nil, duration_minutes: 60)
        ParkingCheck.call(hall: hall, lat: lat, lon: lon, arrive_at: arrive_at, duration_minutes: duration_minutes)
      end

      def category_records(slug:, hall: nil, params: {}, limit: nil)
        query = Query.new(params.merge('hall' => hall).compact)
        query.category_records(slug, limit: limit)
      end

      def category_geo(slug:, hall: nil, params: {}, limit: nil)
        query = Query.new(params.merge('hall' => hall).compact)
        query.category_geo(slug, limit: limit)
      end

      def category_facets(slug:, hall: nil, params: {})
        Query.new(params.merge('hall' => hall).compact).category_facets(slug)
      end

      def source_records(scope:, name:, params: {}, limit: nil)
        Query.new(params).source_records("#{scope}/#{name}", limit: limit)
      end

      def source_geo(scope:, name:, params: {}, limit: nil)
        Query.new(params).source_geo("#{scope}/#{name}", limit: limit)
      end

      def source_facets(scope:, name:, params: {})
        Query.new(params).source_facets("#{scope}/#{name}")
      end

      def source_record(scope:, name:, id:)
        source_slug = "#{scope}/#{name}"
        source = source!(source_slug)
        row = Muni::Store.find(source.emits, id, hall: source.hall) or raise NotFound, 'not found'
        raise NotFound, 'not found' unless row_scoped_to_source?(row, source_slug, source)

        record_payload(row)
      end

      def records_for_type(type, hall: nil, since: nil, limit: 25)
        klass = Muni::Registry.record(type) or raise NotFound, "unknown record type: #{type}"
        where = {}
        where[:hall] = hall if hall
        Muni::Store.query(klass, since: since, limit: limit, **where).map { |row| record_payload(row) }
      end

      def record_for_type(type, id:, hall: nil)
        klass = Muni::Registry.record(type) or raise NotFound, "unknown record type: #{type}"
        row = Muni::Store.find(klass, id, hall: hall) or raise NotFound, "not found: #{type}/#{id}"
        record_payload(row)
      end

      def status
        live_sources = Muni::Registry.sources.keys
        {
          counts:        record_counts,
          cursors:       live_cursors(live_sources),
          orphan_tables: Muni::Store.orphan_tables
        }
      end

      def source_freshness(hall:)
        counts = Muni::Store.counts_by_source(hall: hall)
        live_sources = Muni::Registry.sources.keys.select { |slug| slug.start_with?("#{hall}/") }
        {
          counts:     counts,
          cursors:    live_cursors(live_sources),
          latest_run: latest_runs(live_sources)
        }
      end

      def bootstrap(hall:, category: 'service_requests')
        require_hall!(hall)
        category = category.to_s.empty? ? 'service_requests' : category.to_s
        hall_record = Muni::Hall.find(hall)
        category_list = categories(hall: hall)
        digest_payload = digest(hall: hall)
        dashboard_payload = dashboard(hall: hall)
        freshness = source_freshness(hall: hall)
        muni_payload = municipal_os_payload(
          hall:             hall,
          categories:       category_list,
          digest:           digest_payload,
          dashboard:        dashboard_payload,
          source_freshness: freshness
        )
        {
          hall:              hall_record.to_h,
          capabilities:      hall_record.capabilities,
          selected_category: category,
          categories:        category_list,
          records:           category_records(slug: category, hall: hall, limit: 100),
          geo:               category_geo(slug: category, hall: hall, limit: 250),
          digest:            digest_payload,
          dashboard:         dashboard_payload,
          source_freshness:  freshness
        }.merge(muni_payload)
      end

      def record_payload(row)
        payload = row.to_h
        payload = payload.merge(Muni::ServiceRequestPolicy.enrich(payload)) if row.is_a?(Muni::Records::ServiceRequest)
        payload.transform_values { |value| value.is_a?(Time) ? value.utc.iso8601 : value }
      end

      private

      def require_hall!(hall)
        Muni::Hall.find(hall) or raise NotFound, 'unknown hall'
      end

      def municipal_os_payload(hall:, categories:, digest:, dashboard:, source_freshness:)
        reminders = Muni::Apps.reminders(hall: hall)
        calendar = Muni::Apps.calendar(hall: hall)
        health = Muni::Apps.health(
          source_freshness: source_freshness,
          dashboard:        dashboard
        )
        health['water'] = Muni::Water::Query.new.coverage if Muni::Water.enabled? && Muni::Water::HALLS.include?(hall)
        {
          apps:      Muni::Apps.manifest(
            hall:       hall,
            digest:     digest,
            reminders:  reminders,
            calendar:   calendar,
            health:     health,
            categories: categories
          ),
          health:    health,
          reminders: reminders,
          calendar:  calendar
        }
      end

      def source!(source_slug)
        Muni::Registry.source(source_slug) or raise NotFound, 'unknown source'
      end

      def query_limit(limit)
        lim = (limit || QUERY_LIMIT).to_i
        lim.positive? ? [lim, 500].min : QUERY_LIMIT
      end

      def prediction_limit(limit)
        lim = (limit || 25).to_i
        lim.positive? ? [lim, 100].min : 25
      end

      def record_counts
        Muni::Registry.records.values.map do |klass|
          { record: klass.slug, rows: scoped_count(klass) }
        end
      end

      def scoped_count(klass)
        schema = klass.schema_def
        hall_scoped = schema&.columns&.any? { |col| col.name == :hall }
        live_halls = Muni::Registry.halls.keys
        return Muni::Store.count(klass) unless hall_scoped && live_halls.any?

        live_halls.sum { |hall| Muni::Store.count(klass, hall: hall) }
      end

      def live_cursors(live_sources)
        Muni::Store.db[:meta].where(Sequel.like(:key, 'last_seen:%')).all.filter_map do |r|
          source = r[:key].sub('last_seen:', '')
          next unless live_sources.include?(source)

          { source: source, last_seen: r[:value] }
        end
      end

      def latest_runs(live_sources)
        live_sources.to_h do |slug|
          row = Muni::Store.latest_beat_run(slug)
          [slug, row && {
            started_at: iso_time(row[:started_at]),
            ended_at:   iso_time(row[:ended_at]),
            error:      row[:error]
          }]
        end
      end

      def iso_time(value)
        value.respond_to?(:utc) ? value.utc.iso8601 : value
      end

      def row_scoped_to_source?(row, source_slug, source)
        Muni::Store.source_where(source_slug, source, hall: source.hall).all? do |field, expected|
          row.respond_to?(field) && row.public_send(field).to_s == expected.to_s
        end
      end
    end

    class Query # rubocop:disable Metrics/ClassLength
      FOOD_TRUCK_DAY_ORDER = %w[Monday Tuesday Wednesday Thursday Friday Saturday Sunday].freeze
      FOOD_TRUCK_DAY_ABBR = {
        'Monday' => 'Mon', 'Tuesday' => 'Tue', 'Wednesday' => 'Wed', 'Thursday' => 'Thu',
        'Friday' => 'Fri', 'Saturday' => 'Sat', 'Sunday' => 'Sun'
      }.freeze

      def initialize(params = {})
        @params = params.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      end

      def category_records(slug, limit: nil)
        cat = Muni::View.find(slug) or raise NotFound, 'unknown category'
        lim = query_limit(limit || params['limit'])
        if slug.to_s == 'transit'
          hall = params['hall'] || 'cambridge'
          stations = Muni::Transit.stations(hall: hall)
          return stations.first(lim).map do |s|
            {
              'id'            => s.id,
              'external_id'   => s.id,
              'name'          => s.name,
              'code'          => s.code,
              'routes'        => s.routes,
              'lines'         => s.routes.join(', '),
              'is_transfer'   => s.is_transfer,
              'hall'          => s.hall,
              'lat'           => s.lat,
              'lng'           => s.lng,
              'category'      => 'transit',
              '_record_class' => 'Muni::Transit::Station',
              '_source_slug'  => 'regional/mbta'
            }
          end
        end
        pair_limit = public_food_truck_category?(cat) || default_service_request_category?(cat) ? 5_000 : lim
        pairs = category_pairs(cat, params['hall'], limit: pair_limit)
        return food_truck_group_payloads(pairs).first(lim) if public_food_truck_category?(cat)

        pairs.map do |row, source|
          payload = Data.record_payload(row).merge('_record_class'  => row.class.name,
                                                   '_source_slug'   => source,
                                                   '_incident_kind' => Muni::View.incident_kind(row, source))
          payload.merge!(Muni::Parking.status_payload(row)) if row.is_a?(Muni::Records::MeteredParkingSpace)
          payload
        end
      end

      def category_geo(slug, limit: nil)
        return Muni::Transit.geojson(hall: params['hall']) if slug.to_s == 'transit'

        cat = Muni::View.find(slug) or raise NotFound, 'unknown category'
        lim = query_limit(limit || params['limit'], max: geo_limit_max(slug))
        pair_limit = default_service_request_category?(cat) ? 5_000 : lim
        pairs = category_pairs(cat, params['hall'], limit: pair_limit)
        pairs = Muni::View.merge_row_pairs(pairs, lim) if default_service_request_category?(cat)
        Muni::View.to_category_geojson(pairs, boundary: hall_boundary(params['hall']))
      end

      def category_facets(slug)
        return [] if slug.to_s == 'transit'

        cat = Muni::View.find(slug) or raise NotFound, 'unknown category'
        hall = params['hall']
        Muni::View.category_filter_definitions(cat.slug, hall).filter_map do |definition|
          next Muni::View.time_facet(definition) if definition[:time]
          next Muni::View.synthetic_facet(definition) if definition[:synthetic]

          values = if Muni::View.event_category?(cat.slug)
                     event_facet_values(cat, hall, definition)
                   else
                     category_facet_values(cat, hall, definition)
                   end
          { name: definition[:name], label: definition[:label], values: values }
        end
      end

      def source_records(source_slug, limit: nil)
        source = source!(source_slug)
        category = category_for_source(source_slug)
        lim = query_limit(limit || params['limit'])
        store_limit = source_service_requests_default?(source, category) ? nil : lim
        where = source_record_filters(source_slug, source, category&.slug)
        lifecycle = source_service_requests_default?(source, category)
        rows = query_source_rows(source, limit: store_limit, lifecycle: lifecycle, **where)
        if source_service_requests_default?(source, category)
          rows = rows.select { |row| Muni::ServiceRequestPolicy.visible?(row) }.first(lim)
        end
        rows.map { |row| Data.record_payload(row) }
      end

      def source_geo(source_slug, limit: nil)
        source = source!(source_slug)
        category = category_for_source(source_slug)
        lim = query_limit(limit || params['limit'], max: source_geo_limit_max(source_slug))
        store_limit = source_service_requests_default?(source, category) ? nil : lim
        where = source_record_filters(source_slug, source, category&.slug)
        lifecycle = source_service_requests_default?(source, category)
        rows = query_source_rows(source, limit: store_limit, lifecycle: lifecycle, **where)
        if source_service_requests_default?(source, category)
          rows = rows.select { |row| Muni::ServiceRequestPolicy.visible?(row) }.first(lim)
        end
        geojson = Muni::Helpers::Geo.to_geojson(rows)
        boundary = hall_boundary(params['hall'])
        return geojson unless boundary

        features = geojson[:features].select do |feature|
          lon, lat = feature_anchor(feature)
          Muni::Helpers::Geo.boundary_contains?(boundary, lon, lat)
        end
        geojson.merge(features: features)
      end

      def source_facets(source_slug)
        source = source!(source_slug)
        category = category_for_source(source_slug)
        Muni::View.filter_definitions(source, category&.slug).filter_map do |definition|
          next Muni::View.time_facet(definition) if definition[:time]
          next Muni::View.synthetic_facet(definition) if definition[:synthetic]
          next unless Muni::View.source_supports_filter?(source, definition)

          {
            name:   definition[:name],
            label:  definition[:label],
            values: facet_values(source_slug, source, definition, category&.slug)
          }
        end
      end

      private

      attr_reader :params

      def query_limit(limit, max: 500)
        lim = (limit || QUERY_LIMIT).to_i
        lim.positive? ? [lim, max].min : [QUERY_LIMIT, max].min
      end

      def geo_limit_max(category_slug)
        case category_slug.to_s
        when 'service_requests' then 5_000
        when 'parking', 'environment' then 5_000
        when 'parks' then 2_000
        else 500
        end
      end

      def source_geo_limit_max(source_slug)
        geo_limit_max(category_for_source(source_slug)&.slug)
      end

      def source!(source_slug)
        Muni::Registry.source(source_slug) or raise NotFound, 'unknown source'
      end

      def query_source_rows(source, limit:, lifecycle: false, **where)
        return Muni::Store.query(source.emits, limit: limit, **where) unless lifecycle

        query_lifecycle_service_requests(source.emits, limit: limit, **where)
      end

      def query_lifecycle_service_requests(record_class, limit:, **where)
        schema = record_class.schema_def
        ds = Muni::Store.db[record_class.table_name.to_sym]
        ds = ds.where(where) unless where.empty?
        ds = ds.where(service_request_lifecycle_sql)
        ds = ds.order(Sequel.desc(Muni::Store.time_column(schema)))
        ds = ds.limit(limit) if limit
        ds.all.map { |row| Muni::Store.hydrate(record_class, row, schema) }
      end

      def service_request_lifecycle_sql
        closed = Muni::ServiceRequestPolicy::CLOSED_STATUSES
        cutoff = Time.now.utc - Muni::ServiceRequestPolicy::CLOSED_VISIBLE_SECONDS
        Sequel.lit(
          "(closed_at IS NULL AND lower(coalesce(status, '')) NOT IN ?) OR " \
          'closed_at >= ? OR ' \
          "(lower(coalesce(status, '')) IN ? AND updated_at >= ?)",
          closed, cutoff, closed, cutoff
        )
      end

      def category_pairs(cat, hall, limit:)
        return event_pairs(cat, hall, limit: limit) if Muni::View.event_category?(cat.slug)

        definitions = Muni::View.category_filter_definitions(cat.slug, hall)
        pairs = []
        store_limit = category_store_limit(cat, limit)
        Muni::View.sources_for(cat.slug, hall).each do |source_slug|
          source = Muni::Registry.source(source_slug) or next
          where = source_record_filters(source_slug, source, cat.slug, definitions: definitions, hall: hall)
          query_source_rows(source, limit: store_limit, lifecycle: default_service_request_category?(cat),
                                    **where).each do |row|
            pairs << [row, source_slug]
          end
        end

        pairs = Muni::View.filter_pairs(pairs, post_filters(definitions))
        if default_service_request_category?(cat)
          pairs = pairs.select { |row, _source| Muni::ServiceRequestPolicy.visible?(row) }
        end
        if public_food_truck_category?(cat)
          pairs = Muni::View.surfaceable_food_truck_pairs(pairs)
          pairs = Muni::View.open_food_truck_pairs(pairs) if open_now_filter?(cat)
        end
        return balanced_environment_pairs(pairs, cat, limit) if environment_category?(cat)

        Muni::View.merge_row_pairs(pairs, limit)
      end

      def event_pairs(cat, hall, limit:)
        definitions = Muni::View.category_filter_definitions(cat.slug, hall)
        window = event_window(hall)
        pairs = []
        Muni::View.sources_for(cat.slug, hall).each do |source_slug|
          source = Muni::Registry.source(source_slug) or next
          where = event_record_filters(source, source_slug, definitions)
          Muni::Store.query(source.emits, **where).each do |row|
            pairs << [row, source_slug] if event_overlaps_window?(row, window)
          end
        end

        pairs = Muni::View.filter_pairs(pairs, post_filters(definitions))
        Muni::View.merge_event_row_pairs(pairs, window_start: window[:start], limit: limit,
                                                city: hall || params['hall'] || 'cambridge')
      end

      def open_now_filter?(cat)
        cat.slug.to_s == 'food_trucks' && %w[1 true yes].include?(params['open_now'].to_s.downcase)
      end

      def public_food_truck_category?(cat)
        cat.slug.to_s == 'food_trucks'
      end

      def category_store_limit(cat, limit)
        return nil if default_service_request_category?(cat)
        return 5_000 if public_food_truck_category?(cat)

        limit
      end

      def default_service_request_category?(cat)
        cat.slug.to_s == 'service_requests' && lifecycle_service_request_time_range? &&
          params['time_field'].to_s.empty?
      end

      def source_service_requests_default?(source, category)
        source.emits == Muni::Records::ServiceRequest && category&.slug.to_s == 'service_requests' &&
          lifecycle_service_request_time_range? && params['time_field'].to_s.empty?
      end

      def environment_category?(cat)
        cat.slug.to_s == 'environment'
      end

      def balanced_environment_pairs(pairs, cat, limit)
        grouped = pairs.group_by(&:last)
        active_sources = Muni::View.sources_for(cat.slug, params['hall']).select { |source_slug| grouped[source_slug]&.any? }
        return [] if active_sources.empty?

        per_source_limit = [(limit.to_f / active_sources.size).ceil, 1].max
        source_groups = active_sources.map do |source_slug|
          Muni::View.merge_row_pairs(grouped[source_slug], per_source_limit)
        end
        source_groups.first.zip(*source_groups.drop(1)).flatten(1).compact.first(limit)
      end

      def record_filters(source, category_slug = nil, definitions: nil, source_slug: nil)
        where = {}
        where[:hall] = params['hall'] if params['hall']
        time_field = requested_time_field(source)
        since = since_filter(source, category_slug, time_field, source_slug: source_slug)
        where[:since] = since if since
        where[:since_field] = time_field if since && time_field

        (definitions || Muni::View.filter_definitions(source, category_slug)).each do |definition|
          next if definition[:time]
          next if definition[:synthetic] && definition[:synthetic] != :crash_status

          value = params[definition[:name].to_s]
          next if value.nil? || value.to_s.empty?

          apply_filter_for_source(where, source, definition, value)
        end
        where
      end

      def source_record_filters(source_slug, source, category_slug = nil, definitions: nil, hall: nil)
        record_filters(source, category_slug, definitions: definitions, source_slug: source_slug).merge(
          Muni::Store.source_where(source_slug, source, hall: hall || params['hall'] || source.hall)
        )
      end

      def category_facet_values(cat, hall, definition)
        return food_truck_facet_values(cat, hall, definition) if public_food_truck_category?(cat)

        values = Muni::View.sources_for(cat.slug, hall).flat_map do |source_slug|
          source = Muni::Registry.source(source_slug)
          next [] unless source && Muni::View.source_supports_filter?(source, definition)

          time_field = requested_time_field(source)
          Muni::Store.source_distinct_values(
            source_slug,
            source,
            definition[:field],
            hall:        hall,
            since:       facet_since(source, cat.slug, time_field, source_slug: source_slug),
            since_field: time_field,
            limit:       20
          )
        end
        values.compact.reject { |value| value.to_s.strip.empty? }.uniq.sort.first(20)
      end

      def food_truck_facet_values(cat, hall, definition)
        values = Muni::View.sources_for(cat.slug, hall).flat_map do |source_slug|
          source = Muni::Registry.source(source_slug)
          next [] unless source && Muni::View.source_supports_filter?(source, definition)

          where = Muni::Store.source_where(source_slug, source, hall: hall || source.hall)
          pairs = Muni::Store.query(source.emits, limit: 5_000, **where).map { |row| [row, source_slug] }
          Muni::View.surfaceable_food_truck_pairs(pairs).filter_map do |row, _source|
            row.public_send(definition[:field]) if definition[:field] && row.respond_to?(definition[:field])
          end
        end
        values.compact.reject { |value| value.to_s.strip.empty? }.uniq.sort.first(20)
      end

      def food_truck_group_payloads(pairs)
        pairs.group_by { |row, _source| Muni::View.food_truck_business_id(row) }
             .map { |business_id, group_pairs| food_truck_group_payload(business_id, group_pairs) }
             .sort_by { |payload| -payload.delete(:_sort_time).to_f }
      end

      def food_truck_group_payload(business_id, pairs)
        rows = pairs.map(&:first)
        representative = rows.max_by { |row| food_truck_payload_time(row).to_f }
        entries = food_truck_schedule_entries(rows)
        days = entries.map { |entry| entry[:weekday] }.uniq
        addresses = entries.map { |entry| entry[:address] }.compact.uniq
        payload = Data.record_payload(representative).merge(
          external_id:         business_id,
          business_id:         business_id,
          grouped_record:      true,
          source_external_ids: rows.map(&:external_id).compact.uniq,
          service_days:        days,
          service_day_count:   days.length,
          stop_count:          addresses.length,
          weekday:             food_truck_days_label(days),
          hours:               food_truck_hours_label(entries),
          address:             food_truck_address_label(addresses),
          location:            food_truck_group_location(rows),
          schedule_entries:    entries,
          _record_class:       representative.class.name,
          _source_slug:        pairs.first&.last,
          _incident_kind:      nil,
          _sort_time:          food_truck_payload_time(representative)
        )
        payload[:schedule_summary] = [payload[:weekday], payload[:hours], payload[:address]].compact.join(' / ')
        payload
      end

      def food_truck_schedule_entries(rows)
        entries = rows.sort_by { |row| food_truck_schedule_sort_key(row) }.map do |row|
          {
            external_id: row.external_id,
            weekday:     row.weekday,
            hours:       food_truck_entry_hours(row),
            open_time:   row.open_time,
            close_time:  row.close_time,
            address:     row.address,
            location:    row.location,
            issued_at:   Data.send(:iso_time, row.issued_at)
          }
        end
        entries.uniq { |entry| [entry[:weekday], entry[:hours], entry[:address]] }
      end

      def food_truck_schedule_sort_key(row)
        [
          FOOD_TRUCK_DAY_ORDER.index(row.weekday.to_s) || FOOD_TRUCK_DAY_ORDER.length,
          row.open_time.to_s,
          row.address.to_s
        ]
      end

      def food_truck_days_label(days)
        ordered = days.sort_by { |day| FOOD_TRUCK_DAY_ORDER.index(day.to_s) || FOOD_TRUCK_DAY_ORDER.length }
        indexes = ordered.map { |day| FOOD_TRUCK_DAY_ORDER.index(day.to_s) }.compact
        return 'Daily' if indexes == (0..6).to_a

        food_truck_day_ranges(ordered).join(', ')
      end

      def food_truck_day_ranges(ordered_days)
        ranges = ordered_days.chunk_while do |left, right|
          (FOOD_TRUCK_DAY_ORDER.index(right.to_s) || -2) == (FOOD_TRUCK_DAY_ORDER.index(left.to_s) || -1) + 1
        end
        ranges.map do |range|
          first = FOOD_TRUCK_DAY_ABBR.fetch(range.first.to_s, range.first.to_s)
          last = FOOD_TRUCK_DAY_ABBR.fetch(range.last.to_s, range.last.to_s)
          range.length == 1 ? first : "#{first}-#{last}"
        end
      end

      def food_truck_hours_label(entries)
        hours = entries.map { |entry| entry[:hours] }.compact.uniq
        return hours.first if hours.length <= 1
        return hours.join(' / ') if hours.length == 2

        "#{hours.length} schedules"
      end

      def food_truck_address_label(addresses)
        return addresses.first if addresses.length <= 1

        "#{addresses.length} stops"
      end

      def food_truck_group_location(rows)
        points = rows.filter_map { |row| row.location if row.location.is_a?(Array) && row.location.length >= 2 }
        return nil if points.empty?

        lon = points.sum { |point| point[0].to_f } / points.length
        lat = points.sum { |point| point[1].to_f } / points.length
        [lon, lat]
      end

      def food_truck_entry_hours(row)
        open_time = row.respond_to?(:open_time) ? row.open_time.to_s.strip : ''
        close_time = row.respond_to?(:close_time) ? row.close_time.to_s.strip : ''
        return row.hours if open_time.empty? || close_time.empty?
        return '24 hours' if open_time == close_time

        "#{open_time}-#{close_time}"
      end

      def food_truck_payload_time(row)
        %i[issued_at applicant_submit_date attested_at collected_at last_seen_at].each do |field|
          return row.public_send(field) if row.respond_to?(field) && row.public_send(field)
        end
        Time.at(0)
      end

      def event_facet_values(cat, hall, definition)
        values = event_pairs(cat, hall, limit: 500).filter_map do |row, _source_slug|
          source = Muni::Registry.source(row.source_slug)
          next unless source && Muni::View.source_supports_filter?(source, definition)

          row.public_send(definition[:field]) if definition[:field] && row.respond_to?(definition[:field])
        end
        values.compact.reject { |value| value.to_s.strip.empty? }.uniq.sort.first(20)
      end

      def facet_values(source_slug, source, definition, category_slug)
        time_field = requested_time_field(source)
        Muni::Store.source_distinct_values(
          source_slug,
          source,
          definition[:field],
          hall:        params['hall'] || source.hall,
          since:       facet_since(source, category_slug, time_field, source_slug: source_slug),
          since_field: time_field,
          limit:       20
        )
      end

      def post_filters(definitions)
        definitions.each_with_object({}) do |definition, out|
          next unless definition[:synthetic] && definition[:synthetic] != :crash_status

          value = params[definition[:name].to_s]
          out[definition[:name]] = value if value && !value.to_s.empty?
        end
      end

      def apply_filter_for_source(where, source, definition, value)
        return apply_crash_status_filter_for_source(where, source, value) if definition[:synthetic] == :crash_status
        return where unless Muni::View.source_supports_filter?(source, definition)

        Muni::View.apply_filter(where, definition, value)
      end

      def apply_crash_status_filter_for_source(where, source, value)
        columns = source.emits.schema_def&.column_names || []
        case value
        when 'Fatal'
          where[:fatal] = true if columns.include?(:fatal)
        when 'Injury'
          where[:injury] = true if columns.include?(:injury)
          where[:fatal] = false if columns.include?(:fatal)
        when 'No injury'
          where[:injury] = false if columns.include?(:injury)
          where[:fatal] = false if columns.include?(:fatal)
        end
        where
      end

      def event_record_filters(source, source_slug, definitions)
        where = { source_slug: source_slug, item_type: 'event' }
        where[:hall] = params['hall'] if params['hall']
        definitions.each do |definition|
          next if definition[:time] || definition[:synthetic]

          value = params[definition[:name].to_s]
          next if value.nil? || value.to_s.empty?
          next unless Muni::View.source_supports_filter?(source, definition)

          Muni::View.apply_filter(where, definition, value)
        end
        where
      end

      def event_overlaps_window?(row, window)
        start_at = row.respond_to?(:event_start_at) ? row.event_start_at : nil
        return false unless start_at

        end_at = row.respond_to?(:event_end_at) ? row.event_end_at : nil
        (start_at < window[:end]) && ((end_at || start_at) >= window[:start])
      end

      def event_window(hall)
        city = hall || params['hall'] || 'cambridge'
        now = Time.now.utc
        range = params['time_range'] || Muni::View.default_time_range(:events)
        local_now = Muni::LocalTime.local_time(now, city: city)
        today = local_now.to_date

        case range
        when 'upcoming'
          { start: now, end: now + Muni::View.time_range_seconds('30d') }
        when 'tonight'
          base = local_now.hour < 2 ? today - 1 : today
          { start: local_boundary(base, 17, city), end: local_boundary(base + 1, 2, city) }
        when 'today'
          { start: local_boundary(today, 0, city), end: local_boundary(today + 1, 0, city) }
        when 'tomorrow'
          { start: local_boundary(today + 1, 0, city), end: local_boundary(today + 2, 0, city) }
        when '7d', '30d'
          { start: now, end: now + Muni::View.time_range_seconds(range) }
        else
          { start: now, end: now + Muni::View.time_range_seconds('30d') }
        end
      end

      def local_boundary(date, hour, city)
        Muni::LocalTime.local_to_utc(date.year, date.month, date.day, hour, 0, 0, city: city)
      end

      def since_filter(source, category_slug, time_field = nil, source_slug: nil)
        return nil unless category_slug
        return nil unless Muni::View.timed?(source)
        return nil unless Muni::View.time_windowed_category?(category_slug)
        return nil if Muni::View.event_category?(category_slug)
        return nil if lifecycle_service_requests?(category_slug)

        range = params['time_range'] || Muni::View.default_time_range(category_slug)
        if Muni::View.latest_time_range?(range)
          return source_window_since(source_slug, source, Muni::View.latest_window_seconds(category_slug), time_field)
        end
        if Muni::View.source_anchored_time_category?(category_slug)
          return source_window_since(source_slug, source, range, time_field)
        end

        Time.now.utc - Muni::View.time_range_seconds(range)
      end

      def facet_since(source, category_slug, time_field = nil, source_slug: nil)
        return nil unless category_slug
        return nil unless Muni::View.timed?(source)
        return nil unless Muni::View.time_windowed_category?(category_slug)
        return nil if Muni::View.event_category?(category_slug)
        return nil if lifecycle_service_requests?(category_slug)

        range = params['time_range'] || Muni::View.default_time_range(category_slug)
        if Muni::View.latest_time_range?(range)
          return source_window_since(source_slug, source, Muni::View.latest_window_seconds(category_slug), time_field)
        end
        if Muni::View.source_anchored_time_category?(category_slug)
          return source_window_since(source_slug, source, range, time_field)
        end

        Time.now.utc - Muni::View::TIME_RANGES.fetch('30d')
      end

      def source_window_since(source_slug, source, range, time_field = nil)
        where = source_slug ? Muni::Store.source_where(source_slug, source, hall: params['hall'] || source.hall) : {}
        latest = Muni::Store.latest_time(source.emits, time_field: time_field, **where)
        latest = Time.parse(latest.to_s) unless latest.nil? || latest.is_a?(Time)
        latest ||= Time.now.utc
        seconds = range.is_a?(Numeric) ? range : Muni::View.time_range_seconds(range)
        latest.utc - seconds
      end

      def requested_time_field(source)
        value = params['time_field'].to_s
        return nil if value.empty?

        Muni::Store.time_column(source.emits, preferred: value)
      end

      def lifecycle_service_requests?(category_slug)
        category_slug.to_s == 'service_requests' && lifecycle_service_request_time_range? &&
          params['time_field'].to_s.empty?
      end

      def lifecycle_service_request_time_range?
        range = params['time_range'].to_s
        range.empty? || Muni::View.active_time_range?(range)
      end

      def category_for_source(source_slug)
        hall = source_slug.split('/').first
        Muni::View.all.find { |cat| Muni::View.sources_for(cat.slug, hall) == [source_slug] } ||
          Muni::View.all.find { |cat| cat.source_slugs.include?(source_slug) }
      end

      def feature_anchor(feature)
        geometry = feature[:geometry] || feature['geometry']
        coordinates = geometry && (geometry[:coordinates] || geometry['coordinates'])
        return coordinates if coordinates.is_a?(Array) && coordinates.length == 2 && coordinates.all?(Numeric)

        Muni::Helpers::Geo.centroid(geometry)
      end

      def hall_boundary(slug)
        slug && Muni::Hall.find(slug)&.boundary
      end
    end
  end
end
