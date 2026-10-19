# Cursor validation and SQL filtering share the same immutable request snapshot.
# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Naming/MethodParameterName
require 'base64'
require 'digest'
require 'json'
require 'time'

module Muni
  # Shared SQL access path. No full-ticket materialization before LIMIT.
  class ServiceRequestQuery
    class Invalid < StandardError; end

    TABLE = :service_requests
    SORT_SQL = 'service_requests.efficiency_sort_at'.freeze
    COMPACT_COLUMNS = %i[hall external_id case_type status department neighborhood address location opened_at
                         updated_at acknowledged_at closed_at lifecycle_source_state].freeze
    MAP_COLUMNS = %i[external_id hall case_type address status opened_at updated_at acknowledged_at
                     closed_at lifecycle_source_state].freeze
    META = %w[_record_class _source_slug _source_scope _source_name _incident_kind].freeze

    attr_reader :next_cursor

    def initialize(context, sources:)
      @context = context
      @params = context.send(:params)
      @sources = sources
      fingerprint_params = @params.except('cursor', 'limit', 'slug', 'scope', 'name', 'splat', 'captures')
      @fingerprint = Digest::SHA256.hexdigest(JSON.generate([@sources.sort, fingerprint_params.sort]))
      cursor = decode_cursor
      @as_of = cursor ? Time.iso8601(cursor.fetch('at')) : Time.now.utc
      raise Invalid, 'cursor time is invalid' if @as_of > Time.now.utc + 60

      @last = cursor&.fetch('last')
      @windows = cursor ? cursor.fetch('windows') : {}
      @context.instance_variable_set(:@query_now, @as_of)
    rescue ArgumentError, KeyError, TypeError
      raise Invalid, 'invalid cursor'
    end

    def page(limit: nil, compact: true, metadata: true, maximum: 200)
      rows = records(limit: limit, maximum: maximum, compact: compact)
      items = rows.map do |row|
        payload = Muni::Data.record_payload(row)
        if compact
          payload = payload.slice(*COMPACT_COLUMNS, :reported_at, :display_status, :lifecycle_status, :last_touched_at,
                                  :map_visible)
        end
        payload[:map_signal] = Muni::ServiceRequestPolicy.map_signal(row, now: @as_of) if compact
        if metadata
          payload.merge!('_record_class' => row.class.name, '_source_slug' => "#{row.hall}/service_requests",
                         '_source_scope' => row.hall, '_source_name' => 'service_requests',
                         '_incident_kind' => 'service_request')
        end
        payload['_compact'] = true if compact
        payload
      end
      { items: items, next_cursor: next_cursor, has_more: !next_cursor.nil? }
    end

    def records(limit: nil, maximum: 500, compact: false, map: false)
      requested = (limit || @params['limit'] || 200).to_i
      requested = 200 unless requested.positive?
      requested = [requested, maximum].min
      ds = paged_dataset(map: map)
      if @last
        ds = ds.where(Sequel.lit("(#{SORT_SQL}, service_requests.hall, service_requests.external_id) < (?, ?, ?)",
                                 *@last))
      end
      columns = compact ? COMPACT_COLUMNS.map { |column| Sequel[TABLE][column] } : [Sequel[TABLE].*]
      raw = ds.select(*columns).select_append(Sequel.lit(SORT_SQL).as(:__sort))
              .order(Sequel.desc(Sequel.lit(SORT_SQL)), Sequel.desc(Sequel[TABLE][:hall]),
                     Sequel.desc(Sequel[TABLE][:external_id]))
              .limit(requested + 1).all
      more = raw.length > requested
      raw = raw.first(requested)
      @next_cursor = more ? encode_cursor(raw.last) : nil
      schema = Muni::Records::ServiceRequest.schema_def
      raw.map { |row| Muni::Store.hydrate(Muni::Records::ServiceRequest, row.except(:__sort), schema) }
    end

    def map
      raise Invalid, 'map cursors are not supported' if @params['cursor']
      raise Invalid, 'map requires one hall' unless @sources.length == 1
      raise Invalid, 'bbox is required' unless @params['bbox']

      Muni::Store.db.transaction do
        ds = within_viewport(filtered_dataset(map: true), source_first: true)
        columns = MAP_COLUMNS.map { |column| Sequel[TABLE][column] }
        points = ds.select(*columns, Sequel[:service_request_map_points][:lon],
                           Sequel[:service_request_map_points][:lat]).order(Sequel[TABLE][:external_id]).all
        features = points.map do |row|
          props = { external_id: row[:external_id], hall: row[:hall],
                    case_type: row[:case_type], address: row[:address], status: row[:status],
                    map_signal: Muni::ServiceRequestPolicy.map_signal(row, now: @as_of), _compact: true }
          { type: 'Feature', geometry: { type: 'Point', coordinates: [row[:lon], row[:lat]] },
            properties: props }
        end
        { type: 'FeatureCollection', features: features, represented_count: features.length,
          bbox: bbox, complete: true }
      end
    end

    private

    def paged_dataset(map:)
      in_map_view = @params['map_view'] == '1'
      raise Invalid, 'map view requires bbox' if in_map_view && !@params['bbox']

      ds = filtered_dataset(map: map || in_map_view, indexed: false)
      @params['bbox'] ? within_viewport(ds, source_first: in_map_view) : ds
    end

    def filtered_dataset(map: false, indexed: true)
      clauses = @sources.map do |slug|
        source = Muni::Registry.source(slug)
        where = @context.send(:source_record_filters, slug, source, 'service_requests')
        since = where.delete(:since)
        if @windows.key?(slug)
          since = @windows[slug] && Time.iso8601(@windows[slug])
        else
          @windows[slug] = since&.utc&.iso8601(6)
        end
        time_field = where.delete(:since_field) || :opened_at
        since = nil if map # fixed authoritative report-age policy, independent of list time controls
        clause = Sequel.expr(where.transform_keys { |key| Sequel[TABLE][key] })
        clause &= Sequel.lit("service_requests.#{time_field} >= ?", since) if since
        clause
      end
      db = Muni::Store.db
      ds = db[TABLE]
      if map && indexed
        index = Muni::EfficiencyIndexes.matching_index(db, TABLE, Muni::EfficiencyIndexes::MAP_COLUMNS)
        raise Muni::ServiceRequestMap::Incomplete, 'map filtering index is missing' unless index

        ds = ds.from(Sequel.lit('service_requests INDEXED BY ?', Sequel.identifier(index)))
      end
      ds = ds.where(clauses.empty? ? false : Sequel.|(*clauses))
      return eligible_map_dataset(ds) if map

      return ds if @params['history_view'] == '1' || !@context.send(:lifecycle_service_requests?, 'service_requests')

      status = "lower(trim(coalesce(service_requests.status, ''), " \
               "char(9)||char(10)||char(11)||char(12)||char(13)||' '))"
      visible = "(service_requests.closed_at IS NULL AND #{status} NOT IN ?) " \
                'OR COALESCE(service_requests.closed_at, service_requests.updated_at) >= ?'
      ds.where(Sequel.lit(visible, Muni::ServiceRequestPolicy::CLOSED_STATUSES,
                          @as_of - Muni::ServiceRequestPolicy::CLOSED_VISIBLE_SECONDS))
    end

    def eligible_map_dataset(dataset)
      status = "lower(trim(coalesce(service_requests.status, ''), " \
               "char(9)||char(10)||char(11)||char(12)||char(13)||' '))"
      conditions = [
        "service_requests.closed_at IS NULL AND #{status} IN ?",
        "coalesce(service_requests.lifecycle_source_state, '') NOT IN ('closed', 'missing', 'uncertain')",
        'service_requests.opened_at >= ? AND service_requests.opened_at <= ?',
        'date(service_requests.opened_at, "+0 days") = substr(service_requests.opened_at, 1, 10)',
        'strftime("%H:%M:%S", service_requests.opened_at) = substr(service_requests.opened_at, 12, 8)'
      ]
      dataset.where(Sequel.lit(conditions.join(' AND '), Muni::ServiceRequestPolicy::ACTIVE_STATUSES,
                               @as_of - Muni::ServiceRequestPolicy::MAP_WINDOW_SECONDS, @as_of))
    end

    def bbox
      @bbox ||= begin
        values = @params['bbox'].to_s.split(',').map { |value| Float(value) }
        valid = values.length == 4 && values.all?(&:finite?)
        valid &&= values[0] >= -180 && values[2] <= 180 && values[1] >= -85.05112878 && values[3] <= 85.05112878
        valid &&= values[0] < values[2] && values[1] < values[3]
        raise Invalid, 'invalid bbox' unless valid

        values
      end
    rescue ArgumentError
      raise Invalid, 'invalid bbox'
    end

    def projected_bounds
      @projected_bounds ||= begin
        west, south, east, north = bbox
        xmin, ymax = Muni::ServiceRequestMap.project(west, south)
        xmax, ymin = Muni::ServiceRequestMap.project(east, north)
        [xmin, ymin, xmax, ymax]
      end
    end

    def within_viewport(ds, source_first: false)
      halls = @sources.map { |slug| slug.split('/').first }
      unless Muni::ServiceRequestMap.ready?(halls)
        raise Muni::ServiceRequestMap::Incomplete, 'map projection is incomplete'
      end

      xmin, ymin, xmax, ymax = projected_bounds
      # CROSS JOIN pins ticket filtering before point lookups. The covering index
      # avoids reading large ticket bodies, including for city-wide viewports.
      join_type = source_first ? :cross : :inner
      ds.join_table(join_type, Muni::ServiceRequestMap::TABLE,
                    hall: Sequel[TABLE][:hall], external_id: Sequel[TABLE][:external_id])
        .where(Sequel[:service_request_map_points][:in_boundary] => true)
        .where(Sequel.lit('x >= ? AND x <= ? AND y >= ? AND y <= ?', xmin, xmax, ymin, ymax))
    end

    def decode_cursor
      value = @params['cursor']
      return nil if value.to_s.empty?
      raise Invalid, 'invalid cursor' unless value.is_a?(String) && value.bytesize <= 4096

      cursor = JSON.parse(Base64.urlsafe_decode64(value))
      valid = cursor.is_a?(Hash) && cursor['v'] == 1 && cursor['query'] == @fingerprint
      valid &&= cursor['last'].is_a?(Array) && cursor['last'].length == 3 && cursor['last'].all?(String)
      valid &&= /\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d{1,9})?\z/.match?(cursor['last'][0])
      halls = @params['hall'] ? [@params['hall']] : @sources.map { |slug| slug.split('/').first }
      valid &&= Time.parse(cursor['last'][0]) && halls.include?(cursor['last'][1])
      valid &&= cursor['windows'].is_a?(Hash) && cursor['windows'].keys.sort == @sources.sort
      valid &&= cursor['windows'].values.all? { |value| value.nil? || (value.is_a?(String) && Time.iso8601(value)) }
      raise Invalid, 'cursor does not match this query' unless valid

      cursor
    rescue JSON::ParserError, ArgumentError
      raise Invalid, 'invalid cursor'
    end

    def encode_cursor(row)
      stamp = row.fetch(:__sort)
      stamp = stamp.strftime('%Y-%m-%d %H:%M:%S.%6N') if stamp.respond_to?(:strftime)
      value = JSON.generate(v: 1, query: @fingerprint, at: @as_of.iso8601(6),
                            windows: @windows, last: [stamp, row[:hall], row[:external_id]])
      Base64.urlsafe_encode64(value, padding: false)
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Naming/MethodParameterName
