module Muni
  module Water
    class EvidenceDetail < Query
      def call(id, revision: nil, cutoff: nil)
        Storage.db.transaction do
          @source_checks = {}
          history = Storage.db[:water_revisions].where(evidence_id: id).order(:version).all.map do |entry|
            entry.merge(record: JSON.parse(entry[:record]))
          end
          selected = select_revision(history, revision)
          record = selected ? decorate_record(Eligibility.project(selected[:record]).except('raw')) : current_record(id)
          record['revision_id'] = selected && selected[:id]
          record['revision_version'] = selected && selected[:version]
          record['policy_version'] = DailySummaries::POLICY_VERSION
          record['revision_cutoff'] = revision_cutoff(cutoff, selected)
          dataset = selected ? RecordProjection.snapshot(record['revision_cutoff']) : Storage.evidence
          RecordProjection.attach_candidates([record], dataset: dataset)
          if record.dig('payload', 'publication_group_id')
            RecordProjection.attach_publications([record], dataset: dataset)
          end
          envelope(record: record, revisions: history, selected_revision_id: record['revision_id'],
                   revision_cutoff: record['revision_cutoff'])
        end
      end

      private

      def revision_cutoff(value, selected)
        return Storage.db[:water_revisions].max(:id) || 0 unless value

        cutoff = Integer(value)
        raise Error, 'Revision cutoff precedes selected evidence' if cutoff < ((selected && selected[:id]) || 0)

        cutoff
      rescue ArgumentError, TypeError
        raise Error, 'Revision cutoff must be an integer'
      end

      def select_revision(history, revision)
        return history.last unless revision

        id = Integer(revision)
        selected = history.find { |entry| entry[:id] == id }
        raise Error, 'Revision not found for this evidence' unless selected

        selected
      rescue ArgumentError, TypeError
        raise Error, 'Revision must be an integer'
      end

      def current_record(id)
        row = Storage.evidence.where(external_id: id).first
        raise Error, 'Evidence not found' unless row

        public_record(row)
      end
    end
  end
end
