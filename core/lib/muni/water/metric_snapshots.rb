module Muni
  module Water
    # Keep source/program/method/unit series distinct. Unknown-role publications
    # stay visible alongside confirmed routine samples, never replacing them.
    class MetricSnapshots < Query
      SAMPLE_DATE = 'COALESCE(observed_date, substr(observed_at, 1, 10))'.freeze
      SAMPLE_ROLE = "COALESCE(json_extract(payload, '$.sample_role'), " \
                    "CASE json_extract(payload, '$.routine_sample') WHEN 1 THEN 'routine' ELSE 'unknown' END)".freeze
      def call
        Storage.db.transaction do
          @source_checks = {}
          result = { samples: samples, discharges: discharges }
          RecordProjection.attach(result[:samples] + result[:discharges].filter_map { |entry| entry[:latest] })
          result
        end
      end

      private

      def samples
        rows = Eligibility.apply(Storage.evidence.where(kind: 'laboratory'), calculation: false, primary: true)
        rows = rows.where(Sequel.lit("source_slug != ? OR COALESCE(json_extract(payload, '$.routine_sample'), 1) != 0",
                                     "#{PREFIX}wqp"))
        role = Sequel.lit(SAMPLE_ROLE)
        # Discover series from the covering index; eligibility is checked while
        # seeking their newest samples, rather than on every retained publication.
        groups = Storage.evidence.where(kind: 'laboratory').select(:source_slug, :location_id, :parameter, :unit,
                                                                   :method, :segment)
                        .select_append(role.as(:sample_role)).distinct.all
        selected = groups.flat_map do |group|
          latest_samples(rows.where(role => group[:sample_role]).where(group.except(:sample_role)))
        end
        Eligibility.select(selected).map { |row| decorate_record(row.except('raw')) }
      end

      def latest_samples(dataset)
        date = Sequel.lit(SAMPLE_DATE)
        latest = dataset.order(Sequel.desc(date)).get(date)
        return [] unless latest

        candidates = Eligibility.select(dataset.where(date => latest).order(:external_id).all
                                               .map { |row| Storage.decode(row) })
        if candidates.length > 1
          alternatives = candidates.map { |row| row.slice('external_id', 'value', 'unit', 'observed_at') }
          candidates.each do |row|
            row['selection_status'] = 'multiple_distinct_results'
            row['selection_candidates'] = alternatives
          end
        end
        candidates
      end

      def discharges
        %w[cambridge_cso mwra_cso].map do |id|
          source = "#{PREFIX}#{id}"
          rows = Storage.evidence.where(source_slug: source, kind: 'discharge')
          eligible = rows.exclude(status: %w[retracted needs_review])
                         .where(Sequel.lit("COALESCE(json_extract(payload, '$.countable'), 1) = 1"))
          date = Sequel.lit(SAMPLE_DATE)
          latest = eligible.order(Sequel.desc(date), Sequel.desc(:observed_at), :external_id).first
          { source_slug:  source,
            latest:       public_record(latest),
            needs_review: rows.where(status: 'needs_review').count,
            retracted:    rows.where(status: 'retracted').count }
        end
      end
    end
  end
end
