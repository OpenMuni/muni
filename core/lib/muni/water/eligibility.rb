module Muni
  module Water
    # Shared projection and selection for every read surface. select preserves
    # QC/retracted records for inspection; primary separates routine and unknown.
    module Eligibility
      PRIMARY_EXCLUDED_FLAGS = %w[invalid_numeric_value unparsed_source_value negative_biological_estimate].freeze

      module_function

      def project(record)
        input = record.transform_keys(&:to_s)
        payload = Normalization.decoded(input['payload'])
        normalized = input['normalization_version'] == Normalization::VERSION &&
                     (payload.key?('calculation_eligible') || payload.key?(:calculation_eligible))
        row = Water.canonical(normalized ? input.merge('payload' => payload) : Normalization.call(record))
        payload = row.fetch('payload')
        reasons = payload.fetch('calculation_exclusion_reasons')
        row['eligibility'] = { 'display' => true, 'calculation' => payload['calculation_eligible'],
                               'primary' => primary_eligible?(row), 'reasons' => reasons }
        row
      end

      def calculable?(record)
        version = record['normalization_version'] || record[:normalization_version]
        payload = Normalization.decoded(record['payload'] || record[:payload])
        if version == Normalization::VERSION
          return payload['calculation_eligible'] if payload.key?('calculation_eligible')
          return payload[:calculation_eligible] if payload.key?(:calculation_eligible)
        end
        project(record).dig('eligibility', 'calculation')
      end

      def primary_eligible?(row)
        !Normalization::REJECTED_STATUSES.include?(row['status'].to_s.downcase) &&
          !%w[qc nonroutine].include?(row.dig('payload', 'sample_role')) &&
          !Array(row.dig('payload', 'quality_flags')).intersect?(PRIMARY_EXCLUDED_FLAGS)
      end

      def apply(dataset, calculation: true, primary: false)
        statuses = "COALESCE(LOWER(status), '') NOT IN ('retracted', 'rejected', 'needs_review')"
        dataset = dataset.where(Sequel.lit(statuses))
        return dataset.where(Sequel.lit("json_extract(payload, '$.calculation_eligible') = 1")) if calculation

        roles = "COALESCE(json_extract(payload, '$.sample_role'), 'unknown') NOT IN ('qc', 'nonroutine')"
        dataset = dataset.where(Sequel.lit(roles))
        return dataset unless primary

        excluded = PRIMARY_EXCLUDED_FLAGS.map { |flag| dataset.db.literal(flag) }.join(', ')
        dataset.where(Sequel.lit("NOT EXISTS (SELECT 1 FROM json_each(payload, '$.quality_flags') " \
                                 "WHERE value IN (#{excluded}))"))
      end

      def select(records)
        projected = records.map { |record| project(record) }
        groups = projected.group_by { |row| row.dig('payload', 'publication_group_id') || row['external_id'] }
        selected = groups.values.map do |group|
          representative = group.min_by { |row| row['external_id'].to_s }
          representative['publication_ids'] = group.flat_map do |row|
            row['publication_ids'] || [row['external_id']]
          end.uniq.sort
          representative['publication_count'] = representative['publication_ids'].length
          representative
        end
        mark_candidates(selected)
        selected
      end

      # Returns both sets so unknown-role publications never silently replace a
      # confirmed routine sample. Each set retains distinct comparable series.
      def primary(records)
        selected = select(records).select { |row| row.dig('eligibility', 'primary') }
        %w[routine unknown].to_h do |role|
          eligible = selected.select { |row| row.dig('payload', 'sample_role') == role }
          values = eligible.group_by { |row| series_key(row) }.values.map do |group|
            group.max_by { |row| [row['observed_date'].to_s, row['observed_at'].to_s, row['external_id'].to_s] }
          end
          [role, values]
        end
      end

      def series_key(row)
        [row['source_slug'], row['location_id'], row['parameter'], row.dig('payload', 'normalized_unit'),
         row['method'], row['segment'], row.dig('payload', 'sampling', 'medium'),
         row.dig('payload', 'sampling', 'relative_depth'), row.dig('payload', 'sampling', 'depth')]
      end

      def mark_candidates(records, candidates: records)
        labs = records.select { |row| row['kind'] == 'laboratory' && row['observed_date'] && !row['value'].nil? }
        grouped = candidates.select { |row| row['kind'] == 'laboratory' }.group_by { |row| candidate_key(row) }
        labs.each do |row|
          others = grouped.fetch(candidate_key(row), []).reject { |other| other['source_slug'] == row['source_slug'] }
          next if others.empty?

          row['sample_candidates'] = others.map { |other| candidate(row, other) }
          row['identity_status'] = 'unresolved_cross_source_candidates'
          exclude_unit_conflict(row) if conflicting_units?(row)
        end
      end

      def candidate_key(row)
        row.values_at('location_id', 'observed_date', 'parameter', 'value')
      end

      def conflicting_units?(row)
        row['sample_candidates'].any? { |item| item['relation'].end_with?('unit_conflict') }
      end

      def candidate(row, other)
        relation = if row.dig('payload', 'normalized_unit') == other.dig('payload', 'normalized_unit')
                     'possible_same_sample'
                   else
                     'possible_same_sample_unit_conflict'
                   end
        { 'evidence_id' => other['external_id'], 'relation' => relation }
      end

      def exclude_unit_conflict(row)
        payload = row['payload']
        payload['quality_flags'] |= ['cross_source_unit_conflict']
        payload['calculation_exclusion_reasons'] |= ['cross_source_unit_conflict']
        payload['calculation_eligible'] = false
        row['eligibility']['calculation'] = false
        row['eligibility']['reasons'] = payload['calculation_exclusion_reasons']
      end
    end
  end
end
