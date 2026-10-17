module Muni
  module Water
    class MetricPresentation
      def initialize(overview)
        @overview = overview
      end

      def call
        rows = @overview[:latest] + @overview[:snapshots][:discharges].filter_map { |entry| entry[:latest] }
        @overview.merge(metrics: rows.map { |row| metric(row) }, default_window_days: 30, laboratory_window_days: 365)
      end

      private

      def metric(row)
        candidates = routine_candidates(row)
        { id: Water.hash(DailySummaries.selector(row).merge('evidence_id' => row['external_id'])),
          parameter: row['parameter'], title: (row['parameter'] || row['kind']).tr('_', ' '),
          category: category(row), primary: row,
          qualified_latest: row.dig('payload', 'sample_role') == 'unknown' ? row : nil,
          confirmed_routine: candidates.length == 1 ? candidates.first : nil,
          confirmed_routine_candidates: candidates, coverage: row['eligibility'], limitation: limitation(row) }
      end

      def routine_candidates(row)
        candidates = @overview[:snapshots][:samples].select do |candidate|
          candidate['location_id'] == row['location_id'] && candidate['parameter'] == row['parameter'] &&
            candidate.dig('payload', 'sample_role') == 'routine'
        end
        latest_date = candidates.map { |candidate| candidate['observed_date'].to_s }.max
        candidates.select { |candidate| candidate['observed_date'].to_s == latest_date }
      end

      def category(row)
        return 'flow' if row['kind'] == 'gauge'
        return 'contact' if %w[laboratory prediction program_state discharge].include?(row['kind'])

        'aquatic'
      end

      def limitation(row)
        return 'Modeled boating conditions, not a measured sample.' if row['kind'] == 'prediction'

        location = @overview[:locations].find { |place| place['id'] == row['location_id'] }
        "Applies to #{(location && location['name']) || row['location_id']}; not a river-wide measurement."
      end
    end
  end
end
