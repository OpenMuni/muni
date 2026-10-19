require 'muni/view/food_truck_status'
require 'muni/parking'

module Muni
  module View
    extend FoodTruckStatus

    Category = Struct.new(:slug, :section, :title, :icon, :default_widget, :source_slugs, :empty_message,
                          keyword_init: true)

    CATEGORIES = Muni::Get::Registry.view_categories.map do |row|
      Category.new(**row)
    end.freeze
    CATEGORY_ALIASES = {
      'recent_crashes' => 'crashes'
    }.freeze

    DEFAULT_QUERY_LIMIT = 200
    TIME_RANGES = {
      '1d'  => 1 * 24 * 60 * 60,
      '2d'  => 2 * 24 * 60 * 60,
      '7d'  => 7 * 24 * 60 * 60,
      '14d' => 14 * 24 * 60 * 60,
      '30d' => 30 * 24 * 60 * 60,
      '90d' => 90 * 24 * 60 * 60
    }.freeze
    EVENT_TIME_RANGES = %w[upcoming today tonight tomorrow 7d 30d].freeze
    ACTIVE_RANGE = 'active'.freeze
    LATEST_RANGE = 'latest'.freeze
    DEFAULT_TIME_RANGE = '7d'.freeze
    CATEGORY_TIME_DEFAULTS = {
      'service_requests' => ACTIVE_RANGE,
      'safety'           => LATEST_RANGE,
      'crime_reports'    => LATEST_RANGE,
      'dispatch_calls'   => LATEST_RANGE,
      'permits'          => LATEST_RANGE,
      'crashes'          => LATEST_RANGE,
      'bicycle_counts'   => LATEST_RANGE,
      'zoning_appeals'   => LATEST_RANGE,
      'events'           => 'upcoming'
    }.freeze
    CATEGORY_TIME_VALUES = {
      'service_requests' => [ACTIVE_RANGE, LATEST_RANGE, *TIME_RANGES.keys],
      'safety'           => [LATEST_RANGE, *TIME_RANGES.keys],
      'crime_reports'    => [LATEST_RANGE, *TIME_RANGES.keys],
      'dispatch_calls'   => [LATEST_RANGE, *TIME_RANGES.keys],
      'permits'          => [LATEST_RANGE, *TIME_RANGES.keys],
      'crashes'          => [LATEST_RANGE, *TIME_RANGES.keys],
      'bicycle_counts'   => [LATEST_RANGE, *TIME_RANGES.keys],
      'zoning_appeals'   => [LATEST_RANGE, *TIME_RANGES.keys],
      'events'           => EVENT_TIME_RANGES
    }.freeze
    LATEST_WINDOW_SECONDS = {
      'service_requests' => 7 * 24 * 60 * 60,
      'safety'           => 30 * 24 * 60 * 60,
      'crime_reports'    => 30 * 24 * 60 * 60,
      'dispatch_calls'   => 30 * 24 * 60 * 60,
      'crashes'          => 30 * 24 * 60 * 60,
      'bicycle_counts'   => 365 * 24 * 60 * 60
    }.freeze
    SOURCE_ANCHORED_TIME_CATEGORIES = %w[service_requests permits].freeze
    INVENTORY_CATEGORIES = %w[environment trees parks food_trucks parking].freeze
    CATEGORY_FILTERS = {
      'service_requests'  => [
        { name: 'status', label: 'Status', field: :status },
        { name: 'case_type', label: 'Case type', field: :case_type },
        { name: 'department', label: 'Department', field: :department },
        { name: 'neighborhood', label: 'Neighborhood', field: :neighborhood }
      ],
      'police'            => [
        { name: 'crime_category', label: 'Category', field: :crime_category },
        { name: 'crime_subcategory', label: 'Case type', field: :crime_subcategory },
        { name: 'neighborhood', label: 'Location', field: :neighborhood }
      ],
      'safety'            => [
        { name: 'incident_kind', label: 'Kind', synthetic: :incident_kind,
          values: ['Police log', 'Crime', 'Fire dispatch', 'Police dispatch', 'Recent crash'] },
        { name: 'neighborhood', label: 'Neighborhood', field: :neighborhood }
      ],
      'crime_reports'     => [
        { name: 'crime_category', label: 'Category', field: :crime_category },
        { name: 'neighborhood', label: 'Neighborhood', field: :neighborhood },
        { name: 'reporting_area', label: 'Reporting area', field: :reporting_area }
      ],
      'dispatch_calls'    => [
        { name: 'agency', label: 'Agency', field: :agency },
        { name: 'incident_group', label: 'Group', field: :incident_group },
        { name: 'incident_type', label: 'Type', field: :incident_type },
        { name: 'neighborhood', label: 'Neighborhood', field: :neighborhood }
      ],
      'permits'           => [
        { name: 'status', label: 'Status', field: :status },
        { name: 'permit_type', label: 'Case type', field: :permit_type }
      ],
      'developments'      => [
        { name: 'status', label: 'Status', field: :status },
        { name: 'neighborhood', label: 'Neighborhood', field: :neighborhood }
      ],
      'crashes'           => [
        { name: 'crash_status', label: 'Status', synthetic: :crash_status,
          values: ['Fatal', 'Injury', 'No injury'] },
        { name: 'neighborhood', label: 'Neighborhood', field: :neighborhood },
        { name: 'crash_type', label: 'Case type', field: :crash_type }
      ],
      'traffic_volume'    => [
        { name: 'vehicle_class', label: 'Class', field: :vehicle_class },
        { name: 'intersection', label: 'Intersection', field: :intersection }
      ],
      'bicycle_counts'    => [
        { name: 'count_location', label: 'Location', field: :count_location },
        { name: 'street', label: 'Street', field: :street },
        { name: 'weather', label: 'Weather', field: :weather }
      ],
      'pedestrian_counts' => [
        { name: 'intersection', label: 'Intersection', field: :intersection }
      ],
      'trees'             => [
        { name: 'condition', label: 'Condition', field: :condition },
        { name: 'species_common', label: 'Species/site', field: :species_common }
      ],
      'environment'       => [
        { name: 'kind', label: 'Kind', synthetic: :environment_kind, values: %w[Trees Parks] }
      ],
      'parks'             => [
        { name: 'park_type', label: 'Kind', field: :park_type },
        { name: 'owner', label: 'Owner', field: :owner }
      ],
      'food_trucks'       => [
        { name: 'weekday', label: 'Day', field: :weekday },
        { name: 'truck_name', label: 'Truck', field: :truck_name },
        { name: 'business_name', label: 'Business', field: :business_name }
      ],
      'parking'           => [
        { name: 'meter_status', label: 'Meter status', synthetic: :parking_meter_status,
          values: Muni::Parking::STATUS_VALUES },
        { name: 'max_time', label: 'Max stay', field: :max_time_label },
        { name: 'rate', label: 'Rate', field: :rate_label },
        { name: 'operation_window', label: 'Hours', field: :operation_window }
      ],
      'events'            => [
        { name: 'source_name', label: 'Source', field: :source_name },
        { name: 'category', label: 'Category', field: :category },
        { name: 'location_name', label: 'Location', field: :location_name }
      ]
    }.freeze

    def self.all
      CATEGORIES.map do |category|
        category.dup.tap { |copy| copy.source_slugs = source_slugs_for(category) }
      end
    end

    def self.find(slug)
      key = CATEGORY_ALIASES.fetch(slug.to_s, slug.to_s)
      all.find { |c| c.slug.to_s == key }
    end

    def self.for_hall(hall_slug)
      all.select do |c|
        c.source_slugs.any? { |s| s.start_with?("#{hall_slug}/") }
      end
    end

    def self.sources_for(category_slug, hall_slug)
      cat = find(category_slug) or return []
      cat.source_slugs.select { |s| s.start_with?("#{hall_slug}/") }
    end

    def self.source_slugs_for(category)
      declared = Muni::Registry.sources.values.filter_map do |source|
        source.slug if source.categories.include?(category.slug.to_sym)
      end
      (category.source_slugs + declared).uniq
    end

    def self.primary_source(category, hall_slug)
      sources_for(category, hall_slug).first
    end

    def self.facets_for(record_class)
      return [] unless record_class.respond_to?(:schema_def) && record_class.schema_def

      record_class.schema_def.columns.select do |c|
        c.type == :string && %i[
          status case_type department neighborhood district category
          crime_category crime_subcategory reporting_area permit_type crash_type condition weekday truck_name
          business_name agency incident_type incident_group vehicle_class intersection count_location street
          violation_description violation_code location_type max_time_label rate_label operation_window
          source_name source_type item_type location_name
        ].include?(c.name)
      end.map(&:name)
    end

    def self.filter_definitions(source, category_slug)
      defs = []
      defs << time_filter_definition(category_slug) if timed?(source) && time_windowed_category?(category_slug)
      defs.concat(CATEGORY_FILTERS.fetch(category_slug.to_s, fallback_filters(source)))
      defs
    end

    def self.category_filter_definitions(category_slug, hall_slug)
      cat = find(category_slug)
      return [] unless cat

      defs = []
      any_timed = sources_for(category_slug, hall_slug).any? do |source_slug|
        source = Muni::Registry.source(source_slug)
        source && timed?(source)
      end
      defs << time_filter_definition(category_slug) if time_windowed_category?(category_slug) && any_timed
      primary = primary_source(category_slug, hall_slug)
      source = primary && Muni::Registry.source(primary)
      defs.concat(CATEGORY_FILTERS.fetch(category_slug.to_s, source ? fallback_filters(source) : []))
      defs
    end

    def self.time_windowed_category?(category_slug)
      !INVENTORY_CATEGORIES.include?(category_slug.to_s)
    end

    def self.default_time_range(category_slug)
      CATEGORY_TIME_DEFAULTS.fetch(category_slug.to_s, DEFAULT_TIME_RANGE)
    end

    def self.time_filter_definition(category_slug)
      { name: 'time_range', label: 'Time', time: true, default: default_time_range(category_slug),
        values: time_range_values(category_slug), source_anchored: source_anchored_time_category?(category_slug),
        future: event_category?(category_slug) }
    end

    def self.time_range_values(category_slug)
      CATEGORY_TIME_VALUES.fetch(category_slug.to_s, TIME_RANGES.keys)
    end

    def self.fallback_filters(source)
      facets_for(source.emits).map do |field|
        { name: field.to_s, label: label_for(field), field: field }
      end
    end

    def self.apply_filter(where, definition, value)
      case definition[:synthetic]
      when :crash_status
        apply_crash_status_filter(where, value)
      else
        where[definition[:field]] = value if definition[:field]
      end
      where
    end

    def self.source_supports_filter?(source, definition)
      return false if definition[:synthetic]
      return false unless definition[:field]

      source.emits.schema_def&.column_names&.include?(definition[:field])
    end

    def self.timed?(source)
      !!time_column(source)
    end

    def self.time_column(source)
      Muni::Store.time_column(source.emits)
    end

    def self.time_range_seconds(key)
      TIME_RANGES.fetch(TIME_RANGES.key?(key) ? key : DEFAULT_TIME_RANGE)
    end

    def self.latest_time_range?(key)
      key.to_s == LATEST_RANGE
    end

    def self.active_time_range?(key)
      key.to_s == ACTIVE_RANGE
    end

    def self.source_anchored_time_category?(category_slug)
      SOURCE_ANCHORED_TIME_CATEGORIES.include?(category_slug.to_s)
    end

    def self.event_category?(category_slug)
      category_slug.to_s == 'events'
    end

    def self.latest_window_seconds(category_slug)
      LATEST_WINDOW_SECONDS.fetch(category_slug.to_s, TIME_RANGES.fetch('30d'))
    end

    def self.time_facet(definition)
      {
        name:            definition[:name],
        label:           definition[:label],
        default:         definition[:default],
        values:          definition[:values] || TIME_RANGES.keys,
        source_anchored: definition[:source_anchored] || false,
        future:          definition[:future] || false
      }
    end

    def self.synthetic_facet(definition)
      {
        name:   definition[:name],
        label:  definition[:label],
        values: definition[:values]
      }
    end

    def self.query_category(category_slug, hall: nil, limit: DEFAULT_QUERY_LIMIT, **filters)
      rows = []
      sources_for(category_slug, hall).each do |source_slug|
        source = Muni::Registry.source(source_slug) or next
        where = filters.merge(Muni::Store.source_where(source_slug, source, hall: hall || source.hall))
        rows.concat(Muni::Store.query(source.emits, limit: limit, **where))
      end
      merge_rows(rows, limit)
    end

    def self.query_category_with_sources(category_slug, hall: nil, limit: DEFAULT_QUERY_LIMIT, **filters)
      pairs = []
      sources_for(category_slug, hall).each do |source_slug|
        source = Muni::Registry.source(source_slug) or next
        where = filters.merge(Muni::Store.source_where(source_slug, source, hall: hall || source.hall))
        Muni::Store.query(source.emits, limit: limit, **where).each do |row|
          pairs << [row, source_slug]
        end
      end
      merge_row_pairs(pairs, limit)
    end

    def self.merge_rows(rows, limit)
      rows.sort_by { |r| -time_value(r).to_f }
          .uniq { |r| dedupe_key(r) }
          .first(limit)
    end

    def self.merge_row_pairs(pairs, limit)
      pairs.sort_by { |row, _| -time_value(row).to_f }
           .uniq { |row, _| dedupe_key(row) }
           .first(limit)
    end

    def self.merge_event_row_pairs(pairs, window_start:, limit:, city: 'cambridge')
      pairs.sort_by { |row, source_slug| event_sort_key(row, source_slug, window_start, city) }
           .uniq { |row, _| dedupe_key(row) }
           .first(limit)
    end

    def self.time_value(record)
      h = record.to_h
      %i[
        event_start_at opened_at reported_at received_at occurred_at starts_at observed_at updated_at issued_at
        applied_at published_at active_from introduced_at last_action_at arrival_at hearing_at closed_at collected_at
      ].each do |k|
        v = h[k]
        return v if v
      end
      Time.at(0)
    end

    def self.dedupe_key(record)
      return record.dedupe_key if record.respond_to?(:dedupe_key) && record.dedupe_key

      "#{record.class.name}:#{record.external_id}"
    end

    def self.category_row_count(category_slug, hall, counts)
      return event_row_count(hall) if event_category?(category_slug)

      sources_for(category_slug, hall).sum { |s| counts[s].to_i }
    end

    def self.category_live?(category_slug, hall)
      sources_for(category_slug, hall).any? do |source_slug|
        Muni::Registry.beat(source_slug)
      end
    end

    def self.to_category_geojson(pairs, boundary: nil)
      features = pairs.filter_map do |row, source_slug|
        geometry, geom_field = Muni::Helpers::Geo.feature_geometry(row, :location)
        next nil if geometry.nil?

        anchor = row.respond_to?(:location) ? row.location : Muni::Helpers::Geo.centroid(geometry)
        next nil if anchor.nil?
        next nil unless Muni::Helpers::Geo.boundary_contains?(boundary, anchor[0], anchor[1])

        scope, name = source_slug.split('/', 2)
        row_props = row.respond_to?(:to_h) ? row.to_h.reject { |key, _| key == geom_field } : {}
        if row.is_a?(Muni::Records::ServiceRequest)
          row_props = row_props.merge(Muni::ServiceRequestPolicy.enrich(row_props))
        end
        props = stringify_times(row_props).merge(
          '_source_scope'  => scope,
          '_source_name'   => name,
          '_source_slug'   => source_slug,
          '_record_class'  => row.class.name,
          '_incident_kind' => incident_kind(row, source_slug)
        )
        props.merge!(Muni::Parking.status_payload(row)) if row.is_a?(Muni::Records::MeteredParkingSpace)
        {
          type:       'Feature',
          geometry:   geometry,
          properties: props
        }
      end
      { type: 'FeatureCollection', features: features }
    end

    def self.stringify_times(value)
      case value
      when Time
        value.utc.iso8601
      when Array
        value.map { |item| stringify_times(item) }
      when Hash
        value.transform_values { |item| stringify_times(item) }
      else
        value
      end
    end

    def self.filter_pairs(pairs, filters)
      active = filters.reject { |_, value| value.nil? || value.to_s.empty? }
      return pairs if active.empty?

      pairs.select do |row, source_slug|
        active.all? do |name, value|
          case name.to_s
          when 'incident_kind'
            incident_kind(row, source_slug) == incident_kind_value(value)
          when 'kind'
            environment_kind(row, source_slug) == environment_kind_value(value)
          when 'meter_status'
            Muni::Parking.status_label(row) == value.to_s
          else
            true
          end
        end
      end
    end

    def self.incident_kind(row, source_slug)
      declared = Muni::Registry.source(source_slug)&.incident_kind
      return declared.to_s if declared

      case source_slug
      when 'cambridge/police_log'
        'police_log'
      when 'cambridge/crime_reports'
        'crime'
      when 'cambridge/cpd_crash_log'
        'recent_crash'
      when 'cambridge/dispatch_calls'
        row.respond_to?(:agency) && row.agency.to_s == 'Fire' ? 'dispatch_fire' : 'dispatch_police'
      end
    end

    def self.incident_kind_value(label)
      {
        'Police log'      => 'police_log',
        'Crime'           => 'crime',
        'Fire dispatch'   => 'dispatch_fire',
        'Police dispatch' => 'dispatch_police',
        'Recent crash'    => 'recent_crash'
      }.fetch(label.to_s, label.to_s)
    end

    def self.environment_kind(row, source_slug)
      return 'trees' if source_slug == 'cambridge/tree_inventory' || row.is_a?(Muni::Records::Tree)

      'parks' if source_slug == 'cambridge/parks' || row.is_a?(Muni::Records::Park)
    end

    def self.environment_kind_value(label)
      {
        'Trees' => 'trees',
        'Parks' => 'parks'
      }.fetch(label.to_s, label.to_s.downcase)
    end

    def self.event_sort_key(row, source_slug, window_start, city)
      start_at = row.respond_to?(:event_start_at) ? row.event_start_at : nil
      [
        event_day_rank(start_at, window_start, city),
        event_secondary_rank(row, window_start),
        start_at&.to_f || Float::INFINITY,
        event_source_rank(source_slug)
      ]
    end
    private_class_method :event_sort_key

    def self.event_secondary_rank(row, window_start)
      return 2 if event_all_day?(row)

      start_at = row.respond_to?(:event_start_at) ? row.event_start_at : nil
      end_at = row.respond_to?(:event_end_at) ? row.event_end_at : nil
      return 1 if start_at && end_at && start_at < window_start && end_at > window_start

      0
    end
    private_class_method :event_secondary_rank

    def self.event_day_rank(start_at, window_start, city)
      return Float::INFINITY unless start_at

      effective_start = [start_at, window_start].max
      Muni::LocalTime.local_time(effective_start, city: city).to_date.jd
    end
    private_class_method :event_day_rank

    def self.event_all_day?(row)
      metadata = row.respond_to?(:metadata) ? row.metadata : {}
      metadata['all_day'] || metadata[:all_day]
    end
    private_class_method :event_all_day?

    def self.event_source_rank(source_slug)
      find(:events)&.source_slugs&.index(source_slug).to_i
    end
    private_class_method :event_source_rank

    def self.event_row_count(hall)
      sources_for(:events, hall).sum do |source_slug|
        Muni::Store.count(Muni::Records::DigestItem, hall: hall, source_slug: source_slug, item_type: 'event')
      end
    end
    private_class_method :event_row_count

    def self.apply_crash_status_filter(where, value)
      case value
      when 'Fatal'
        where[:fatal] = true
      when 'Injury'
        where[:injury] = true
        where[:fatal] = false
      when 'No injury'
        where[:injury] = false
        where[:fatal] = false
      end
    end
    private_class_method :apply_crash_status_filter

    def self.label_for(field)
      field.to_s.tr('_', ' ').split.map(&:capitalize).join(' ')
    end
    private_class_method :label_for
  end
end
