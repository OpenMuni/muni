require 'muni/water/spill_buffer'

module Muni
  module Water
    # Prepare JSON and fingerprints before the publication lock. The unique
    # evidence/version constraint rejects a stale prepared publication.
    class EvidenceWriter
      BATCH_SIZE = 500
      attr_reader :prepared

      def initialize(now: Time.now.utc)
        @now = now
      end

      def prepare(records)
        close
        @prepared = SpillBuffer.new
        @statements = SpillBuffer.new
        records.each_slice(BATCH_SIZE) do |batch|
          latest = latest_versions(batch)
          entries = batch.filter_map { |record| prepare_record(record, latest[record[:external_id]]) }
          publication_statements(entries).each { |statement| @statements << statement } unless entries.empty?
          entries.each { |entry| @prepared << entry.slice(:record, :before) }
          Thread.current[:muni_scheduler_yield]&.call
        end
        self
      end

      def publish
        @statements.each { |statement| Storage.db.run(statement) }
        prepared.length
      end

      def call(records)
        prepare(records).publish
      end

      def changes
        prepared.lazy.map { |entry| { before: entry[:before], after: entry[:record] } }
      end

      def close
        @prepared&.close
        @statements&.close
      end

      private

      def publication_statements(prepared)
        updates = Evidence.schema_def.column_names.to_h { |key| [key, Sequel[:excluded][key]] }
        evidence = Storage.evidence.insert_conflict(target: :external_id, update: updates)
        prepared.each_slice(BATCH_SIZE).flat_map do |batch|
          insert_statements(Storage.db[:water_revisions], batch.map { |entry| entry[:revision] }) +
            insert_statements(evidence, batch.map { |entry| entry[:row] })
        end
      end

      def insert_statements(dataset, rows)
        columns = rows.first.keys
        dataset.multi_insert_sql(columns, rows.map { |row| columns.map { |column| row[column] } })
      end

      def latest_versions(records)
        history = Storage.db[:water_revisions].where(evidence_id: records.map { |row| row[:external_id] })
        ids = history.group(:evidence_id).select { max(id).as(:id) }
        Storage.db[:water_revisions].where(id: ids).all.to_h { |row| [row[:evidence_id], row] }
      end

      def prepare_record(record, latest)
        record = normalized_record(record)
        fingerprint = semantic_fingerprint(record)
        return if latest && latest[:fingerprint] == fingerprint

        before = latest && JSON.parse(latest[:record])
        return if older_retrieval?(record, before)

        record[:payload] = record[:payload].merge(
          source_fingerprint: Water.hash(record[:raw]),
          change_kind:        before && before['raw'] == Water.canonical(record[:raw]) ? 'normalization' : 'publication'
        )
        row = record.merge(payload: Water.json(record[:payload]), raw: Water.json(record[:raw]))
        revision_record = Water.canonical(record).merge('fetched_at' => record[:fetched_at]&.iso8601(6))
        revision = { evidence_id: record[:external_id], version: latest ? latest[:version] + 1 : 1,
                     fingerprint: fingerprint, record: Water.json(revision_record), detected_at: @now }
        { row: row, revision: revision, record: record, before: before }
      end

      def normalized_record(record)
        record = record.dup
        %i[observed_at published_at fetched_at].each { |key| record[key] = Water.time(record[key]) }
        record = Normalization.call(record)
        record[:publication_group_id] = record.dig(:payload, :publication_group_id)
        Evidence.schema_def.column_names.to_h { |key| [key, record[key]] }
      end

      def semantic_fingerprint(record)
        semantic = Water.canonical(record).except('fetched_at', 'parser_version')
        %w[reviewed_at source_fingerprint change_kind].each { |key| semantic['payload']&.delete(key) }
        Water.hash(semantic)
      end

      def older_retrieval?(record, before)
        previous_fetch = before && Water.time(before['fetched_at'])
        previous_fetch && record[:fetched_at] && previous_fetch > record[:fetched_at]
      end
    end
  end
end
