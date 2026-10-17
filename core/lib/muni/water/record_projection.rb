module Muni
  module Water
    # Call while holding the same read transaction that selected the records.
    # One lookup per batch binds displayed values to their immutable revisions.
    module RecordProjection
      module_function

      def snapshot(cutoff, columns: Evidence.schema_def.column_names)
        current = Storage.db[:water_revisions].max(:id) || 0
        return Storage.evidence.select(*columns) if cutoff >= current

        return Storage.evidence.where(Sequel.lit('0 = 1')) if cutoff.zero?

        # Most fixed-cutoff pages differ from current evidence by only a few
        # publications. Reconstruct those identities, not the entire archive.
        history = Storage.db[:water_revisions]
        changed = history.where { id > cutoff }.select(:evidence_id)
        latest = history.where(evidence_id: changed).where { id <= cutoff }
                                                    .group(:evidence_id).select { max(id).as(:id) }
        expressions = columns.map do |column|
          Sequel.function(:json_extract, :record, "$.#{column}").as(column)
        end
        old = history.where(id: latest).select(*expressions)
        current = Storage.evidence.exclude(external_id: changed).select(*columns)
        current.union(old, all: true)
      end

      def attach_publications(records, dataset:)
        groups = records.filter_map { |record| record.dig('payload', 'publication_group_id') }
        members = dataset.where(publication_group_id: groups).select(:publication_group_id, :external_id)
                         .all.group_by { |row| row[:publication_group_id] }
        legacy = legacy_publications(records, dataset: dataset)
        records.each do |record|
          group = record.dig('payload', 'publication_group_id')
          next unless group

          ids = members.fetch(group, []).map { |row| row[:external_id] } + legacy.fetch(group, [])
          record['publication_ids'] = ids.uniq.sort
          record['publication_count'] = record['publication_ids'].length
        end
      end

      # Earlier immutable revisions predate the materialized group column. Limit
      # their raw comparison to the selected station/date, at the same cutoff.
      def legacy_publications(records, dataset:)
        labs = records.select do |record|
          record['source_slug'] == "#{PREFIX}crwa_laboratory" && record.dig('payload', 'publication_group_id')
        end
        return {} if labs.empty?

        date = Sequel.lit('COALESCE(observed_date, substr(observed_at, 1, 10))')
        legacy = dataset.where(source_slug: "#{PREFIX}crwa_laboratory", publication_group_id: nil,
                               location_id: labs.map { |record| record['location_id'] }.uniq)
                        .where(date => labs.map { |record| record['observed_date'] }.uniq)
        legacy.select(:source_slug, :external_id, :raw).all.each_with_object({}) do |row, groups|
          raw = Normalization.decoded(row[:raw])
          next if raw.empty?

          group = Water.hash([row[:source_slug], raw.except('FID', 'GlobalID')])
          (groups[group] ||= []) << row[:external_id]
        end
      end

      def revisions(records, cutoff:)
        ids = records.map { |record| record['external_id'] || record[:external_id] }
        latest = Storage.db[:water_revisions].where(evidence_id: ids).where { id <= cutoff }
                                                                     .group(:evidence_id).select { max(id).as(:id) }
        Storage.db[:water_revisions].where(id: latest).select(:id, :evidence_id, :version)
               .all.to_h { |row| [row[:evidence_id], row] }
      end

      def attach(records, cutoff: Storage.db[:water_revisions].max(:id) || 0, dataset: Storage.evidence)
        versions = revisions(records, cutoff: cutoff)
        records.each do |record|
          revision = versions[record['external_id']]
          record['revision_id'] = revision && revision[:id]
          record['revision_version'] = revision && revision[:version]
          record['revision_cutoff'] = cutoff
          record['policy_version'] = DailySummaries::POLICY_VERSION
        end
        attach_candidates(records, dataset: dataset)
        records
      end

      def attach_candidates(records, dataset:)
        labs = records.select { |row| row['kind'] == 'laboratory' && row['observed_date'] && !row['value'].nil? }
        return if labs.empty?

        # Source/date bounds use the existing index; fetch only candidate identity
        # columns, never whole raw publications. Filters must not hide other feeds.
        fields = %w[location_id observed_date parameter value]
        sources = Catalog.definitions.keys.map { |id| "#{PREFIX}#{id}" }
        rows = dataset.where(source_slug: sources)
        fields.each { |field| rows = rows.where(field.to_sym => labs.map { |row| row[field] }.uniq) }
        candidates = rows.select(*%i[external_id source_slug kind location_id observed_date parameter value unit])
                         .all.map do |row|
          unit = Normalization.normalized_unit(row[:unit])
          row.transform_keys(&:to_s).merge('payload' => { 'normalized_unit' => unit })
        end
        Eligibility.mark_candidates(labs, candidates: candidates)
      end

      def attach_raw(records, cutoff: Storage.db[:water_revisions].max(:id) || 0)
        versions = revisions(records, cutoff: cutoff)
        records.each { |record| record[:revision_id] = versions.dig(record[:external_id], :id) }
      end
    end
  end
end
