require 'sequel'
require 'json'
require 'fileutils'
require 'time'
require 'tempfile'
require 'muni/service_request_map'
require 'muni/efficiency_indexes'

module Muni
  # rubocop:disable-next Metrics/ModuleLength
  module Store
    @mutex = Mutex.new
    BACKUP_DAILY_RETENTION = 7
    BACKUP_WEEKLY_RETENTION = 4
    OPERATIONAL_TABLES = %i[
      analytics_results
      service_request_map_points efficiency_index_changes
      beats_log
      geo_layers
      meta
      water_locations water_associations water_revisions water_runs water_checkpoints
      water_signals water_signal_versions water_responses water_pending_pages
      water_batches water_calculation_jobs water_daily_summaries water_daily_summary_versions water_schedule_state
    ].freeze

    # rubocop:disable-next Metrics/ClassLength
    class << self
      def db
        @db ||= open_db
      end

      def reset!
        @db&.disconnect
        @db = nil
      end

      def with_writer(&block)
        @mutex.synchronize do
          File.open("#{Muni::Config.db_path}.writer.lock", File::RDWR | File::CREAT, 0o600) do |lock|
            lock.flock(File::LOCK_EX)
            block.call
          ensure
            lock.flock(File::LOCK_UN)
          end
        end
      end

      # ---------- record persistence ----------

      def ensure_tables!
        with_writer do
          db.create_table?(:meta) do
            String   :key, primary_key: true
            String   :value, text: true
            DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
          end

          db.create_table?(:beats_log) do
            primary_key :id
            String   :beat_slug, index: true
            DateTime :started_at, index: true
            DateTime :ended_at
            Integer  :rows_in
            Integer  :rows_upserted
            String   :error, text: true
          end

          db.create_table?(:geo_layers) do
            String   :slug, primary_key: true
            String   :geojson, text: true
            DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
          end

          ensure_feature_tables!
          Muni::Registry.records.each_value { |klass| ensure_record_table!(klass) }
          Muni::Water::Storage.ensure_tables!
          Muni::ServiceRequestMap.ensure_schema!
          Muni::EfficiencyIndexes.ensure_sort_column!(db)
        end
      end

      def ensure_feature_tables!
        ensure_analytics_tables!
      end

      def ensure_analytics_tables!
        db.create_table?(:analytics_results) do
          String   :hall, null: false
          String   :kind, null: false
          String   :key, null: false
          String   :payload, text: true
          DateTime :generated_at, index: true
          Integer  :source_row_count
          DateTime :source_max_at
          primary_key %i[hall kind key]
          index %i[hall kind]
        end
      end

      def ensure_record_table!(klass)
        schema = klass.schema_def
        return if schema.nil?

        table = klass.table_name.to_sym
        if db.table_exists?(table)
          ensure_record_columns!(table, schema)
          ensure_hall_scoped_primary_key!(table, schema)
          ensure_record_indexes!(table, schema)
          return
        end

        create_record_table(table, schema)
        ensure_record_indexes!(table, schema)
        Muni::Logger.instance.info("Store: created table #{table} (pk=#{schema.primary_key || :id})")
      end

      def ensure_record_columns!(table, schema)
        existing = db.schema(table).map { |column, _| column }
        missing = schema.columns.reject { |column| existing.include?(column.name) }

        return if missing.empty?

        db.alter_table(table) do
          missing.each do |column_def|
            opts = { null: true }
            opts[:default] = column_def.default unless column_def.default.nil?
            add_column column_def.name, Muni::Store.sequel_type(column_def.type), opts
          end
        end
        Muni::Logger.instance.info("Store: added #{missing.map(&:name).join(', ')} to #{table}")
      end

      def ensure_record_indexes!(table, schema)
        cols = schema.columns
        has_hall = cols.any? { |c| c.name == :hall }
        time_col = pick_time_column(schema)
        add_record_index(table, [:hall, time_col]) if has_hall && time_col
        ensure_service_request_indexes!(table, schema) if table.to_sym == :service_requests
        ensure_domain_indexes!(table, schema)
      end

      def ensure_domain_indexes!(table, schema)
        columns = schema.column_names
        candidates = {
          crime_reports:            [%i[hall crime_category], %i[hall neighborhood]],
          building_permits:         [%i[hall status], %i[hall permit_type]],
          new_construction_permits: [%i[hall status]],
          trees:                    [%i[hall species_common]],
          parks:                    [%i[hall park_type]],
          metered_parking_spaces:   [%i[hall space_id]],
          zoning_appeals:           [%i[hall status]],
          development_projects:     [%i[hall status]]
        }.fetch(table.to_sym, [])
        candidates.each { |index| add_record_index(table, index) if (index - columns).empty? }
      end

      def ensure_service_request_indexes!(table, schema)
        cols = schema.column_names
        if cols.include?(:hall) && cols.include?(:opened_at) && cols.include?(:status)
          add_record_index(table, %i[hall opened_at status])
        end
        add_record_index(table, %i[hall updated_at]) if cols.include?(:hall) && cols.include?(:updated_at)
        add_record_index(table, %i[hall closed_at]) if cols.include?(:hall) && cols.include?(:closed_at)
        add_record_index(table, %i[hall status]) if cols.include?(:hall) && cols.include?(:status)
      end

      def add_record_index(table, columns)
        columns = Array(columns).compact
        return if columns.empty?

        desired_index = :"#{table}_#{columns.join('_')}_index"
        existing_indexes = db.fetch('PRAGMA index_list(?)', table.to_s).map { |row| row[:name].to_sym }
        return if Muni::EfficiencyIndexes.equivalent?(db, table, columns)
        raise "Index definition conflicts with #{desired_index}" if existing_indexes.include?(desired_index)

        db.alter_table(table) do
          add_index columns, name: desired_index, if_not_exists: true
        end
        Muni::Logger.instance.info("Store: added index #{desired_index}")
      rescue Sequel::DatabaseError => e
        # Index may already exist with different name, ignore
        Muni::Logger.instance.debug("Store: index creation skipped - #{e.message}")
      end

      # Column construction mirrors the schema DSL's supported types and
      # options, so its branching is deliberately kept in one migration path.
      # rubocop:disable-next Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def create_record_table(table, schema)
        cols = schema.columns
        has_hall = cols.any? { |c| c.name == :hall }
        scoped_primary = hall_scoped_schema?(schema)
        time_col = pick_time_column(schema)
        db.create_table(table) do
          cols.each do |c|
            opts = { null: true }
            opts[:primary_key] = true if c.primary && !scoped_primary
            opts[:default] = c.default unless c.default.nil?
            column c.name, Muni::Store.sequel_type(c.type), opts
          end
          primary_key %i[hall external_id] if scoped_primary
          primary_key :id if cols.none?(&:primary)
          cols.select(&:indexed).each { |c| index c.name }
          index :hall if has_hall
          index [:hall, time_col] if has_hall && time_col
        end
      end

      def ensure_hall_scoped_primary_key!(table, schema)
        return unless hall_scoped_schema?(schema)

        primary = db.fetch("PRAGMA table_info(#{table})").all
                    .select { |column| column[:pk].to_i.positive? }
                    .sort_by { |column| column[:pk].to_i }
                    .map { |column| column[:name].to_sym }
        return if primary == %i[hall external_id]

        blank_hall = Sequel.|({ hall: nil }, { hall: '' })
        duplicate = db[table].where(blank_hall).count
        db[table].where(blank_hall).update(hall: 'cambridge') if duplicate.positive?
        conflict = db[table].group(:hall, :external_id).having(Sequel.lit('COUNT(*) > 1')).first
        raise "duplicate Hall/external ID in #{table}: #{conflict.inspect}" if conflict

        temporary = :"#{table}_hall_pk_migration"
        raise "unfinished Hall key migration exists: #{temporary}" if db.table_exists?(temporary)

        db.transaction do
          create_record_table(temporary, schema)
          db[temporary].insert(db[table].select(*schema.column_names))
          db.drop_table(table)
          db.rename_table(temporary, table)
        end
        Muni::Logger.instance.info("Store: migrated #{table} primary key to (hall, external_id)")
      end

      def hall_scope(hall)
        { hall: hall }
      end

      def source_where(source_slug, source_class = nil, hall: nil)
        source_class ||= Muni::Registry.source(source_slug)
        record_class = source_record_class(source_class)
        columns = record_class&.schema_def&.column_names || []
        where = {}
        where[:hall] = hall if hall && columns.include?(:hall)
        where[:source_slug] = source_slug.to_s if columns.include?(:source_slug)
        where
      end

      def source_count(source_slug, source_class = nil, hall: nil)
        source_class ||= Muni::Registry.source(source_slug)
        return 0 unless source_class

        count(source_record_class(source_class), **source_where(source_slug, source_class, hall: hall))
      end

      def source_latest_time(source_slug, source_class = nil, hall: nil, time_field: nil)
        source_class ||= Muni::Registry.source(source_slug)
        return nil unless source_class

        latest_time(
          source_record_class(source_class),
          time_field: time_field,
          **source_where(source_slug, source_class, hall: hall)
        )
      end

      def source_distinct_values(source_slug, source_class, field, hall: nil, since: nil, since_field: nil, limit: 20)
        distinct_values(
          source_record_class(source_class),
          field,
          since:       since,
          since_field: since_field,
          limit:       limit,
          **source_where(source_slug, source_class, hall: hall)
        )
      end

      def sequel_type(type)
        case type
        when :string  then String
        when :text    then 'TEXT'
        when :integer then Integer
        when :float   then Float
        when :boolean then TrueClass
        when :time    then DateTime
        when :point   then String # JSON-encoded [lon, lat]
        when :json    then 'TEXT'
        else String
        end
      end

      def upsert(record)
        klass = record.class
        schema = klass.schema_def or raise "Record #{klass} has no schema"
        pk = record_primary_key(schema)
        row = serialize_attrs(record.to_h, schema)
        validate_hall_scope!(schema, row)
        persisted = false

        with_writer do
          persisted = upsert_row(db[klass.table_name.to_sym], pk, row)
        end
        persisted
      end

      def bulk_upsert(records, batch_size: 750)
        records.each_slice(batch_size).sum do |batch|
          next 0 if batch.empty?

          klass = batch.first.class
          raise ArgumentError, 'bulk upsert records must share a class' unless batch.all?(klass)

          schema = klass.schema_def or raise "Record #{klass} has no schema"
          pk = record_primary_key(schema)
          rows = batch.map do |record|
            serialize_attrs(record.to_h, schema).tap do |row|
              validate_hall_scope!(schema, row)
            end
          end
          persisted = with_writer do
            db.transaction do
              dataset = db[klass.table_name.to_sym]
              rows.count { |row| upsert_row(dataset, pk, row) }
            end
          end
          persisted
        end
      end

      # Source records, derived points, and checkpoint commit as one unit.
      def persist_lifecycle_batch(records, key:, expected:, checkpoint:, missing: [])
        accepted = []
        with_writer do
          db.transaction do
            actual = db[:meta].where(key: key).get(:value)
            raise 'lifecycle checkpoint changed concurrently' unless actual == expected

            records.each do |record|
              schema = record.class.schema_def
              row = serialize_attrs(record.to_h, schema)
              validate_hall_scope!(schema, row)
              accepted << record if upsert_row(db[:service_requests], %i[hall external_id], row)
            end
            now = Time.now.utc
            missing.each do |old|
              # Missing is a verification result, never a closure or deletion.
              db[:service_requests].where(old.slice(:hall, :external_id, :status, :updated_at, :collected_at))
                                   .update(lifecycle_source_state: 'missing', lifecycle_checked_at: now)
            end
            values = { key => JSON.generate(checkpoint) }
            (records.map(&:hall) + missing.map { |row| row[:hall] }).uniq.each do |hall|
              values["changed_at:#{hall}/service_requests"] = now.iso8601(6)
            end
            values.each do |name, value|
              attrs = { key: name, value: value, updated_at: now }
              db[:meta].insert_conflict(target: :key, update: attrs.except(:key)).insert(attrs)
            end
          end
        end
        accepted.length
      end

      # +since+ filters on the record's primary time column when one exists;
      # otherwise it is a no-op (see +pick_time_column+).
      def query(klass, since: nil, since_field: nil, limit: nil, order: nil, **where)
        schema = klass.schema_def or raise "Record #{klass} has no schema"
        ds = db[klass.table_name.to_sym]
        hall = where.delete(:hall)
        ds = ds.where(hall_scope(hall)) if hall
        ds = ds.where(where) unless where.empty?
        time_col = query_time_column(schema, since_field)
        ds = apply_since_filter(ds, time_col, since)
        ds = ds.order(Sequel.desc(query_order_column(schema, time_col, order)))
        ds = ds.limit(limit) if limit
        ds.all.map { |row| hydrate(klass, row, schema) }
      end

      def find(klass, pk_value, hall: nil)
        schema = klass.schema_def or raise "Record #{klass} has no schema"
        pk = schema.primary_key or raise "Record #{klass} needs a primary key for find"
        where = { pk => pk_value }
        where[:hall] = hall if hall && schema.column_names.include?(:hall)
        row = db[klass.table_name.to_sym].where(where).first
        row && hydrate(klass, row, schema)
      end

      def count(klass, **where)
        ds = db[klass.table_name.to_sym]
        hall = where.delete(:hall)
        ds = ds.where(hall_scope(hall)) if hall
        ds = ds.where(where) unless where.empty?
        ds.count
      end

      def delete_before(klass, field, value, **where)
        schema = klass.schema_def or raise "Record #{klass} has no schema"
        field = field.to_sym
        raise "Record #{klass} has no #{field} column" unless schema.column_names.include?(field)

        with_writer do
          ds = db[klass.table_name.to_sym]
          hall = where.delete(:hall)
          ds = ds.where(hall_scope(hall)) if hall
          ds = ds.where(where) unless where.empty?
          ds.where(Sequel.lit("#{field} < ?", time_or_nil(value) || value)).delete
        end
      end

      def enforce_source_retention(source_class, now: Time.now.utc)
        days = source_class&.retention_days
        return 0 unless days&.positive?

        klass = source_class.emits
        field = time_column(klass)
        return 0 unless field

        where = source_where(source_class.slug, source_class, hall: source_class.hall)
        delete_before(klass, field, now - (days * 86_400), **where)
      end

      def counts_by_source(hall: nil)
        sources = Muni::Registry.sources
        sources = sources.select { |slug, _| slug.start_with?("#{hall}/") } if hall
        sources.each_with_object({}) do |(slug, source_klass), out|
          out[slug] = source_count(slug, source_klass, hall: hall || source_klass.hall)
        end
      end

      def orphan_tables
        expected = (Muni::Registry.records.values.map { |klass| klass.table_name.to_sym } + OPERATIONAL_TABLES).uniq
        orphaned = db.tables.map(&:to_sym).reject do |table|
          expected.include?(table) || table.to_s.start_with?('sqlite_')
        end.sort

        orphaned.map do |table|
          {
            table:  table.to_s,
            rows:   db[table].count,
            status: 'orphaned',
            action: 'review_export_before_prune'
          }
        rescue Sequel::DatabaseError
          {
            table:  table.to_s,
            rows:   nil,
            status: 'orphaned',
            action: 'review_export_before_prune'
          }
        end
      end

      def last_beats_log_id
        db[:beats_log].max(:id) || 0
      end

      # ---------- meta + beats log ----------

      def last_seen(source_slug)
        row = db[:meta].where(key: meta_key(source_slug)).first
        row && row[:value] && Time.parse(row[:value])
      end

      def meta(key)
        row = db[:meta].where(key: key).first
        row && row[:value]
      end

      def set_meta(key, value)
        with_writer do
          db[:meta].insert_conflict(target: :key, update: { value:      value.to_s,
                                                            updated_at: Sequel::CURRENT_TIMESTAMP })
                   .insert(key: key, value: value.to_s)
        end
      end

      def bump_seen(source_slug, time)
        set_meta(meta_key(source_slug), time.utc.iso8601)
      end

      def mark_checked(source_slug, time = Time.now.utc, changed: false)
        set_meta("checked_at:#{source_slug}", time.utc.iso8601)
        set_meta("changed_at:#{source_slug}", time.utc.iso8601) if changed
      end

      def last_checked(source_slug)
        value = meta("checked_at:#{source_slug}")
        value && Time.parse(value)
      end

      def log_beat_run(slug:, started_at:, ended_at:, rows_in: 0, rows_upserted: 0, error: nil)
        with_writer do
          db[:beats_log].insert(
            beat_slug:     slug,
            started_at:    started_at,
            ended_at:      ended_at,
            rows_in:       rows_in,
            rows_upserted: rows_upserted,
            error:         error&.to_s
          )
        end
      end

      def recent_beat_runs(limit: 50)
        db[:beats_log].order(Sequel.desc(:started_at)).limit(limit).all
      end

      def latest_beat_run(slug, successful: nil)
        ds = db[:beats_log].where(beat_slug: slug.to_s)
        unless successful.nil?
          ds = successful ? ds.where(error: nil) : ds.exclude(error: nil)
        end
        ds.order(Sequel.desc(:started_at)).first
      end

      # ---------- analytics cache ----------

      def upsert_analytics_result(hall:, kind:, key:, payload:, generated_at: Time.now.utc,
                                  source_row_count: nil, source_max_at: nil)
        row = {
          hall:             hall.to_s,
          kind:             kind.to_s,
          key:              key.to_s,
          payload:          payload.is_a?(String) ? payload : JSON.generate(payload),
          generated_at:     time_or_nil(generated_at),
          source_row_count: source_row_count,
          source_max_at:    time_or_nil(source_max_at)
        }

        with_writer do
          db[:analytics_results]
            .insert_conflict(target: %i[hall kind key],
                             update: row.except(:hall, :kind, :key))
            .insert(row)
        end
      end

      def analytics_result(hall:, kind:, key:)
        row = db[:analytics_results].where(hall: hall.to_s, kind: kind.to_s, key: key.to_s).first
        row && deserialize_analytics_result(row)
      end

      def analytics_results(hall:, kind: nil)
        ds = db[:analytics_results].where(hall: hall.to_s)
        ds = ds.where(kind: kind.to_s) if kind
        ds.order(:kind, :key).all.map { |row| deserialize_analytics_result(row) }
      end

      # ---------- internals ----------

      def serialize_attrs(attrs, schema)
        out = {}
        schema.columns.each do |c|
          val = attrs[c.name]
          if val.nil?
            # Explicit null lifecycle fields are meaningful (e.g. a reopened
            # request clears its previous closure date). Other attributes and
            # datasets retain their existing sparse-update semantics.
            out[c.name] = nil if nullable_lifecycle_field?(schema, c.name) && attrs.key?(c.name)
            next
          end

          out[c.name] = case c.type
                        when :time  then val.is_a?(Time) ? val.utc : Time.parse(val.to_s).utc
                        when :point then JSON.generate(val)
                        when :json  then val.is_a?(String) ? val : JSON.generate(val)
                        when :boolean then val ? 1 : 0
                        else val
                        end
        end
        out
      end

      def nullable_lifecycle_field?(schema, name)
        schema == Muni::Records::ServiceRequest.schema_def && %i[status opened_at closed_at location].include?(name)
      end

      def stale_timestamped_update?(dataset, primary_key, row)
        return stale_service_request?(dataset, primary_key, row) if dataset.first_source_table == :service_requests

        incoming = time_or_nil(row[:updated_at])
        key = Array(primary_key).to_h { |column| [column, row[column]] }
        return false unless incoming && key.values.all?

        current = dataset.where(key).select(:updated_at).first
        current_time = time_or_nil(current && current[:updated_at])
        current_time && current_time > incoming
      end

      # rubocop:disable-next Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def stale_service_request?(dataset, primary_key, row)
        key = Array(primary_key).to_h { |column| [column, row[column]] }
        current = dataset.where(key).first
        return false unless current

        if row[:hall] == 'boston' && current[:source_revision_at] && !row[:source_revision_at]
          return true # unversioned discovery cannot undo a reconciled snapshot
        end

        incoming, previous = lifecycle_versions(row, current)
        return true if unresolved_closure_replay?(current, row, incoming)
        return true if previous && (!incoming || incoming < previous)
        return true if incoming == previous && historical_closure_replay?(current, row, incoming)
        return false if corroborated_source_reopening?(current, row, incoming)

        stale_reopening?(current, row, incoming, previous)
      end

      def stale_reopening?(current, row, incoming, previous)
        terminal_request?(current) && !terminal_request?(row) && (!incoming || !previous || incoming <= previous)
      end

      def unresolved_closure_replay?(current, row, incoming)
        return false unless current[:lifecycle_source_state] == 'uncertain' && !terminal_request?(row)

        evidence = current[:lifecycle_evidence]
        evidence = JSON.parse(evidence) if evidence.is_a?(String)
        return false unless evidence && evidence['unversioned_closure']

        observed = time_or_nil(current[:lifecycle_checked_at])
        !incoming || !observed || incoming <= observed
      end

      def lifecycle_versions(row, current)
        incoming = time_or_nil(row[:updated_at]) || time_or_nil(row[:closed_at])
        previous = time_or_nil(current[:updated_at]) || time_or_nil(current[:closed_at])
        revision = time_or_nil(row[:source_revision_at])
        old_revision = time_or_nil(current[:source_revision_at])
        if row[:hall] == 'boston' && revision
          # CKAN exposes snapshot revisions, not per-ticket modification times.
          unversioned = terminal_request?(current) ? time_or_nil(current[:collected_at]) : previous
          previous = old_revision || unversioned || previous
          incoming = revision
        end
        [incoming, previous]
      end

      def terminal_request?(attrs)
        attrs[:closed_at] || Muni::ServiceRequestPolicy::CLOSED_STATUSES.include?(attrs[:status].to_s.strip.downcase)
      end

      def reopening_evidence?(attrs)
        evidence = attrs[:lifecycle_evidence]
        evidence = JSON.parse(evidence) if evidence.is_a?(String)
        evidence && evidence['confirmed_reopened']
      end

      def historical_closure_replay?(current, row, incoming)
        # A delayed export can still carry the historical closure date.
        reopening_evidence?(current) && incoming && !current[:closed_at] && row[:closed_at] &&
          time_or_nil(row[:closed_at]) < incoming &&
          Muni::ServiceRequestPolicy::ACTIVE_STATUSES.include?(row[:status].to_s.downcase)
      end

      def corroborated_source_reopening?(current, row, incoming)
        reopening_evidence?(row) && incoming && current[:closed_at] &&
          Muni::ServiceRequestPolicy::ACTIVE_STATUSES.include?(current[:status].to_s.downcase) &&
          incoming > time_or_nil(current[:closed_at])
      end

      def source_record_class(source_class)
        source_class.respond_to?(:emits) ? source_class.emits : source_class
      end

      def record_primary_key(schema)
        pk = schema.primary_key or raise 'Record needs a primary key for persistence'
        hall_scoped_schema?(schema) ? %i[hall external_id] : pk
      end

      def hall_scoped_schema?(schema)
        schema.primary_key == :external_id && schema.column_names.include?(:hall)
      end

      def validate_hall_scope!(schema, row)
        return unless hall_scoped_schema?(schema)
        return unless row[:hall].to_s.strip.empty?

        raise ArgumentError, 'Hall-scoped records require a hall'
      end

      # This mutates storage and reports whether a stale-write guard skipped it;
      # a predicate suffix would misleadingly imply a read-only query.
      # rubocop:disable-next Naming/PredicateMethod
      def upsert_row(dataset, primary_key, row)
        if stale_timestamped_update?(dataset, primary_key, row)
          quarantine_unversioned_closure(dataset, primary_key, row)
          return false
        end

        keys = Array(primary_key)
        if dataset.first_source_table == :service_requests
          current = dataset.where(row.slice(*keys)).first
          # Keep the last source evidence when a faster discovery feed omits it.
          row[:lifecycle_evidence] ||= current && current[:lifecycle_evidence]
          if row.key?(:status)
            status = row[:status].to_s.strip.downcase
            row[:lifecycle_source_state] = if row[:closed_at] || Muni::ServiceRequestPolicy::CLOSED_STATUSES.include?(status)
                                             'closed'
                                           elsif Muni::ServiceRequestPolicy::ACTIVE_STATUSES.include?(status)
                                             'active'
                                           else
                                             'uncertain'
                                           end
            row[:lifecycle_checked_at] = Time.now.utc
          end
        end
        db.transaction do
          dataset.insert_conflict(target: keys, update: row.except(*keys)).insert(row)
          if dataset.first_source_table == :service_requests && db.table_exists?(Muni::ServiceRequestMap::TABLE)
            Muni::ServiceRequestMap.persist(current.to_h.merge(row))
          end
        end
        true
      end

      def quarantine_unversioned_closure(dataset, primary_key, row)
        return unless dataset.first_source_table == :service_requests && row[:lifecycle_evidence]
        return unless terminal_request?(row)
        return if row[:updated_at] || row[:closed_at] || row[:source_revision_at]

        # Closure is authoritative but its ordering against a stored reopening
        # is unknown. Preserve the lifecycle; do not advertise it as open.
        evidence = row[:lifecycle_evidence]
        evidence = JSON.parse(evidence) if evidence.is_a?(String)
        evidence = JSON.generate(evidence.merge('unversioned_closure' => true))
        dataset.where(row.slice(*Array(primary_key))).update(lifecycle_source_state: 'uncertain',
                                                             lifecycle_checked_at:   Time.now.utc,
                                                             lifecycle_evidence:     evidence)
      end

      def hydrate(klass, row, schema)
        coerced = {}
        schema.columns.each do |c|
          v = row[c.name]
          coerced[c.name] = case c.type
                            when :point then v.nil? ? nil : JSON.parse(v.to_s)
                            when :json  then v.nil? ? nil : JSON.parse(v.to_s)
                            when :boolean then hydrate_boolean(v)
                            else v
                            end
        end
        klass.new(**coerced)
      end

      def pick_time_column(schema)
        time_cols = schema.columns.select { |c| c.type == :time }
        preferred = %i[opened_at reported_at occurred_at received_at starts_at event_start_at meeting_at published_at
                       observed_at updated_at issued_at applied_at plant_date fetched_at last_seen_at collected_at]
        preferred.each do |name|
          return name if time_cols.any? { |c| c.name == name }
        end
        time_cols.first&.name
      end

      def query_time_column(schema, since_field)
        since_field ? requested_time_column(schema, since_field) : pick_time_column(schema)
      end

      def apply_since_filter(dataset, time_col, since)
        return dataset unless since && time_col

        dataset.where(Sequel.lit("#{time_col} >= ?", since))
      end

      def query_order_column(schema, time_col, order)
        order || time_col || pick_time_column(schema) || schema.primary_key || :id
      end

      def requested_time_column(schema, field)
        candidate = field&.to_sym
        schema.columns.any? { |c| c.type == :time && c.name == candidate } ? candidate : nil
      end

      def hydrate_boolean(value)
        return nil if value.nil?
        return value if [true, false].include?(value)

        normalized = value.to_s.strip.downcase
        return true if %w[1 true t yes y].include?(normalized)
        return false if %w[0 false f no n].include?(normalized)

        false
      end

      def deserialize_analytics_result(row)
        row.merge(
          payload:       parse_json(row[:payload]),
          generated_at:  time_or_nil(row[:generated_at]),
          source_max_at: time_or_nil(row[:source_max_at])
        )
      end

      def parse_json(value)
        return {} if value.nil? || value.to_s.empty?

        JSON.parse(value.to_s)
      rescue JSON::ParserError
        {}
      end

      def time_or_nil(value)
        return nil if value.nil?
        if value.is_a?(Time)
          return Time.utc(value.year, value.month, value.day, value.hour, value.min, value.sec + value.subsec)
        end
        return value.to_time.utc if value.respond_to?(:to_time)

        Time.parse(value.to_s).utc
      rescue ArgumentError
        nil
      end

      def meta_key(source_slug)
        "last_seen:#{source_slug}"
      end

      def open_db
        configure_timezones!
        path = Muni::Config.db_path
        FileUtils.mkdir_p(File.dirname(path))
        # Apply connection-local settings to every pool member, including ones
        # opened later by Puma. Bound temporary sorts on the shared 2-GB VM.
        d = Sequel.sqlite(path, max_connections: 4, timeout: 5000, synchronous: :normal, temp_store: :file,
                          after_connect: lambda { |connection|
                            connection.execute_batch('PRAGMA cache_size=-2000; PRAGMA wal_autocheckpoint=1000; ' \
                                                     'PRAGMA journal_size_limit=67108864')
                          })
        d.run('PRAGMA journal_mode=WAL')
        d
      end

      def configure_timezones!
        Sequel.application_timezone = :utc
        Sequel.database_timezone = :utc
        Sequel.typecast_timezone = :utc
      end

      def optimize!
        with_writer do
          db.run('PRAGMA wal_checkpoint(TRUNCATE)')
          db.run('PRAGMA optimize')
          db.run('ANALYZE')
        end
        Muni::Logger.instance.info('Store: optimized database')
      end

      def perform_maintenance!(now: Time.now.utc)
        return unless maintenance_enabled?

        backup!(now: now) if backup_mode == 'local' && meta('maintenance:last_backup') != now.strftime('%Y-%m-%d')
        week = now.strftime('%G-W%V')
        return unless now.wday.zero? && meta('maintenance:last_optimize') != week

        optimize!
        set_meta('maintenance:last_optimize', week)
      end

      def backup!(now: Time.now.utc)
        backup_dir = ENV.fetch('MUNI_BACKUP_PATH', File.join(Muni::Config.data_dir, 'backups'))
        FileUtils.mkdir_p(backup_dir)
        daily = File.join(backup_dir, "daily-#{now.strftime('%Y-%m-%d')}.sqlite3")
        captured_at = ensure_daily_backup(daily, now.strftime('%Y-%m-%d'))
        if now.wday.zero?
          weekly = File.join(backup_dir, "weekly-#{now.strftime('%G-W%V')}.sqlite3")
          atomic_backup(weekly) { |temporary| FileUtils.cp(daily, temporary) } unless valid_backup?(weekly)
        end
        rotate_backups!(backup_dir, 'daily-*.sqlite3', keep: BACKUP_DAILY_RETENTION)
        rotate_backups!(backup_dir, 'weekly-*.sqlite3', keep: BACKUP_WEEKLY_RETENTION)
        record_backup_success(now.strftime('%Y-%m-%d'), captured_at: captured_at)
        daily
      rescue StandardError => e
        record_backup_failure(e)
        raise
      end

      def ensure_daily_backup(path, date)
        if valid_backup?(path)
          previous = db[:meta].where(key: 'maintenance:last_backup', value: date).first
          return previous[:updated_at] if previous && previous[:updated_at]

          return File.mtime(path).utc
        end
        atomic_backup(path) { |temporary| online_backup(temporary) }
      end

      def online_backup(path)
        OnlineBackup.new(db).call(path)
      end

      def atomic_backup(path)
        Tempfile.create(['.muni-backup-', '.sqlite3'], File.dirname(path)) do |temporary|
          temporary.close
          yield temporary.path
          captured_at = Time.now.utc
          raise Sequel::DatabaseError, 'Backup validation failed' unless valid_backup?(temporary.path)

          File.open(temporary.path, File::RDONLY, &:fsync)
          File.rename(temporary.path, path)
          File.open(File.dirname(path), File::RDONLY, &:fsync)
          captured_at
        end
      end

      def valid_backup?(path)
        return false unless File.file?(path) && File.size(path).positive?

        copy = Sequel.sqlite(path, readonly: true)
        copy.fetch('PRAGMA quick_check').all == [{ quick_check: 'ok' }] && copy.table_exists?(:meta)
      rescue Sequel::DatabaseError
        false
      ensure
        copy&.disconnect
      end

      def record_backup_success(date, captured_at:)
        rows = [{ key: 'maintenance:last_backup', value: date, updated_at: captured_at },
                { key: 'maintenance:last_backup_verified', value: date, updated_at: Time.now.utc }]
        with_writer do
          db.transaction do
            rows.each { |row| db[:meta].insert_conflict(target: :key, update: row.except(:key)).insert(row) }
          end
        end
      end

      def record_backup_failure(error)
        set_meta('maintenance:last_backup_failure', JSON.generate(at:          Time.now.utc.iso8601(6),
                                                                  error_class: error.class.name))
      rescue StandardError
        # A failed metadata write must not replace the original backup failure.
        nil
      end

      def rotate_backups!(directory, pattern, keep:)
        Dir.glob(File.join(directory, pattern)).reverse.drop(keep).each { |path| FileUtils.rm_f(path) }
      end

      def maintenance_enabled?
        default = ENV['RACK_ENV'].to_s == 'production' ? '1' : '0'
        ENV.fetch('MUNI_MAINTENANCE_ENABLED', default) == '1'
      end

      def backup_mode
        mode = ENV.fetch('MUNI_BACKUP_MODE', 'local')
        raise ArgumentError, 'Invalid backup mode' unless %w[local external disabled].include?(mode)

        mode
      end

      def time_column(klass_or_schema, preferred: nil)
        schema = klass_or_schema.respond_to?(:schema_def) ? klass_or_schema.schema_def : klass_or_schema
        return nil unless schema

        requested_time_column(schema, preferred) || pick_time_column(schema)
      end
    end
  end
end

require 'muni/store/read'
require 'muni/store/online_backup'
