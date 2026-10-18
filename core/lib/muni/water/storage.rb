module Muni
  module Water
    module Storage
      TABLES = %i[water_locations water_associations water_revisions water_runs water_checkpoints
                  water_signals water_signal_versions water_responses water_pending_pages water_batches
                  water_calculation_jobs water_daily_summaries water_daily_summary_versions water_schedule_state].freeze

      module_function

      def db = Muni::Store.db

      # Called inside Store's existing single-writer migration lock.
      def ensure_tables!
        db.create_table?(:water_locations) do
          String :id, primary_key: true
          String :waterbody, default: 'charles'
          String :payload, text: true
        end
        db.create_table?(:water_associations) do
          String :waterbody
          String :hall
          primary_key %i[waterbody hall]
        end
        db.create_table?(:water_revisions) do
          primary_key :id
          String :evidence_id, null: false, index: true
          Integer :version, null: false
          String :fingerprint, null: false
          String :record, text: true, null: false
          DateTime :detected_at, null: false
          index %i[evidence_id version], unique: true
        end
        ensure_run_tables!
        ensure_response_provenance!
        ensure_signal_tables!
        ensure_processing_tables!
        ScheduleStore.ensure_table! if defined?(ScheduleStore)
        Muni::Store.add_record_index(:water_evidence, %i[source_slug location_id parameter observed_at])
        Muni::Store.add_record_index(:water_evidence, %i[kind observed_at])
        Muni::Store.add_record_index(:water_evidence,
                                     %i[source_slug location_id parameter unit method segment observed_at])
        Muni::Store.add_record_index(:water_evidence, %i[source_slug observed_date])
        Muni::Store.add_record_index(:water_evidence, [:observed_date])
        Muni::Store.add_record_index(:water_evidence, %i[source_slug observed_at])
        Muni::Store.add_record_index(:water_evidence, [:publication_group_id])
        Muni::Store.add_record_index(:water_responses, %i[source_slug url digest])
        Muni::Store.add_record_index(:water_runs, %i[source_slug started_at])
        ensure_read_indexes!
        seed_catalog!
      end

      # Narrow covering indexes keep grouping/sorting away from raw evidence.
      # Expressions exactly match the shared UI/API/CLI pagination projection.
      def ensure_read_indexes!
        indexes = {
          water_revision_lookup:    'water_revisions (evidence_id, id)',
          water_record_order:       "water_evidence (#{RecordPage::ORDER_DATE} DESC, external_id)",
          water_kind_order:         "water_evidence (kind, #{RecordPage::ORDER_DATE} DESC, external_id)",
          water_publication_groups: 'water_evidence (kind, COALESCE(publication_group_id, external_id), external_id)',
          water_series_selectors:   'water_evidence (source_slug, location_id, parameter, unit, kind, ' \
                                    'method, segment, observed_at DESC, external_id)',
          water_latest_batch:       'water_batches (source_slug, started_at DESC)',
          water_source_jobs:        'water_calculation_jobs (source_slug, status)',
          water_source_runs:        'water_runs (source_slug, id DESC)',
          water_legacy_groups:      'water_evidence (source_slug, publication_group_id, location_id, ' \
                                    'COALESCE(observed_date, substr(observed_at, 1, 10)))',
          water_lab_latest:         'water_evidence (kind, source_slug, location_id, parameter, unit, ' \
                                    'method, segment, ' \
                                    "#{MetricSnapshots::SAMPLE_ROLE}, " \
                                    "#{MetricSnapshots::SAMPLE_DATE} DESC, external_id)",
          water_summary_window:     'water_daily_summaries (source_slug, policy_version, date)'
        }
        indexes.each { |name, definition| db.run("CREATE INDEX IF NOT EXISTS #{name} ON #{definition}") }
      end

      def ensure_processing_tables!
        ensure_batch_tables!
        ensure_calculation_tables!
        ensure_summary_tables!
      end

      def ensure_batch_tables!
        db.create_table?(:water_batches) do
          String :id, primary_key: true
          Integer :run_id, index: true
          String :source_slug, index: true
          String :status
          String :signature
          String :query_signature
          String :parser_signature
          String :source_edition, text: true
          String :manifest, text: true
          DateTime :started_at
          DateTime :retrieved_at
          DateTime :normalized_at
          DateTime :published_at
          DateTime :calculated_at
          Float :writer_seconds
          String :error, text: true
        end
        columns = db.schema(:water_batches).map(&:first)
        %i[query_signature parser_signature source_edition].each do |name|
          db.alter_table(:water_batches) { add_column name, String, text: true } unless columns.include?(name)
        end
        %i[normalization_seconds normalization_allocations normalization_gc_ms writer_wait_seconds
           calculation_seconds calculation_allocations calculation_gc_ms].each do |name|
          db.alter_table(:water_batches) { add_column name, Float } unless columns.include?(name)
        end
      end

      def ensure_calculation_tables!
        db.create_table?(:water_calculation_jobs) do
          primary_key :id
          String :batch_id, index: true
          String :source_slug, index: true
          String :payload, text: true
          String :status, default: 'pending', index: true
          String :error, text: true
          DateTime :created_at
          DateTime :completed_at
          Integer :attempts, default: 0
          DateTime :retry_at
          DateTime :claimed_at
          String :claim_token
        end
        job_columns = db.schema(:water_calculation_jobs).map(&:first)
        { attempts: Integer, retry_at: DateTime, claimed_at: DateTime, claim_token: String }.each do |name, type|
          db.alter_table(:water_calculation_jobs) { add_column name, type } unless job_columns.include?(name)
        end
      end

      def ensure_summary_tables!
        db.create_table?(:water_daily_summary_versions) do
          String :id, primary_key: true
          String :series_key
          String :date
          String :source_slug
          String :selector, text: true
          String :payload, text: true
          String :policy_version
          Integer :revision_cutoff
          DateTime :calculated_at
          index %i[series_key date]
        end
        db.create_table?(:water_daily_summaries) do
          String :series_key
          String :date
          String :source_slug, index: true
          String :selector, text: true
          String :payload, text: true
          String :policy_version
          Integer :revision_cutoff
          DateTime :calculated_at
          primary_key %i[series_key date]
        end
      end

      def ensure_run_tables!
        db.create_table?(:water_pending_pages) do
          String :source_slug
          String :url, text: true
          DateTime :retrieved_at
          DateTime :snapshot_at
          String :headers, text: true
          File :body
          primary_key %i[source_slug url]
        end
        unless db.schema(:water_pending_pages).any? { |column, _| column == :snapshot_at }
          db.alter_table(:water_pending_pages) { add_column :snapshot_at, DateTime }
        end
        db.create_table?(:water_runs) do
          primary_key :id
          String :source_slug, index: true
          DateTime :started_at
          DateTime :ended_at
          String :status
          String :error, text: true
          Integer :records, default: 0
          Integer :changes, default: 0
          String :metadata, text: true
        end
        db.create_table?(:water_checkpoints) do
          String :source_slug, primary_key: true
          String :payload, text: true
        end
        db.create_table?(:water_responses) do
          primary_key :id
          String :source_slug, index: true
          String :url, text: true
          DateTime :retrieved_at, index: true
          String :digest
          String :headers, text: true
          File :body
        end
      end

      def ensure_response_provenance!
        %i[water_pending_pages water_responses].each do |table|
          columns = db.schema(table).map(&:first)
          %i[final_url redirects].each do |name|
            db.alter_table(table) { add_column name, String, text: true } unless columns.include?(name)
          end
        end
      end

      def ensure_signal_tables!
        %i[water_signals water_signal_versions].each do |table|
          db.create_table?(table) do
            String :id, primary_key: true
            String :signal_key, index: true
            String :kind
            String :status
            DateTime :generated_at
            String :payload, text: true
          end
        end
      end

      def seed_catalog!
        HALLS.each do |hall|
          db[:water_associations].insert_conflict.insert(waterbody: 'charles', hall: hall)
        end
        Catalog.seed_locations.each do |location|
          db[:water_locations].insert_conflict.insert(id: location[:id], waterbody: 'charles',
                                                      payload: Water.json(location))
        end
        # River boundary geometry is intentionally not bundled without redistribution rights.
        # Collector-supplied locations and the source-linked seed locations remain available.
      end

      def checkpoint(slug)
        JSON.parse(db[:water_checkpoints].where(source_slug: slug).get(:payload) || '{}')
      end

      # Read presentation metadata without decoding large incremental cursors.
      def checkpoint_fields(slug, fields)
        columns = fields.map { |field| db.literal(field) + ", json(payload -> '$.#{field}')" }.join(', ')
        value = db[:water_checkpoints].where(source_slug: slug)
                                      .get(Sequel.lit("json_object(#{columns})"))
        JSON.parse(value || '{}')
      end

      def save_checkpoint(slug, payload)
        row = { source_slug: slug, payload: Water.json(payload) }
        db[:water_checkpoints].insert_conflict(target: :source_slug, update: row).insert(row)
      end

      def evidence
        db[:water_evidence]
      end

      def decode(row)
        return nil unless row

        row.transform_keys(&:to_s).transform_values { |value| value.is_a?(Time) ? value.utc.iso8601 : value }
           .tap do |record|
          %w[payload raw].each { |key| record[key] = JSON.parse(record[key] || '{}') }
        end
      end

      def locations
        db[:water_locations].order(:id).all.map { |row| JSON.parse(row[:payload]) }
      end

      def save_location(location)
        row = { id: location.fetch('id'), waterbody: 'charles', payload: Water.json(location) }
        db[:water_locations].insert_conflict(target: :id, update: row).insert(row)
      end

      def record_count(slug)
        evidence.where(source_slug: slug).count
      end
    end
  end
end
