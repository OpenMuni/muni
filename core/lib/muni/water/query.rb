require 'base64'

module Muni
  module Water
    class Query
      def initialize(now: Time.now.utc, include_coverage: true)
        @now = now
        @include_coverage = include_coverage
      end

      def coverage
        Coverage.new(now: @now).call
      end

      def overview
        Storage.db.transaction { overview_snapshot }
      end

      def overview_snapshot
        @source_checks = {}
        groups = Storage.evidence.exclude(kind: %w[discharge official_advisory laboratory])
                        .select(*DailySummaries::SELECTOR.map(&:to_sym)).distinct.all
        latest = groups.filter_map do |group|
          row = Eligibility.apply(Storage.evidence.where(group), calculation: false, primary: true)
                           .order(Sequel.desc(:observed_at), :external_id).first
          public_record(row)
        end
        snapshots = MetricSnapshots.new(now: @now).call
        latest.concat(snapshots[:samples])
        latest = Eligibility.select(latest)
        RecordProjection.attach(latest)
        advisories = Storage.evidence.where(kind: 'official_advisory').all.map { |row| public_record(row) }
        RecordProjection.attach(advisories)
        envelope(latest: latest, advisories: advisories, locations: locations, documents: Catalog::DOCUMENTS,
                 methodology: methodology, snapshots: snapshots)
      end

      def metrics
        MetricPresentation.new(overview).call
      end

      def locations
        Storage.locations + %w[2 3 4 5].map do |reach|
          { 'id' => "reach-#{reach}", 'name' => "CRWA boating reach #{reach}", 'kind' => 'reach',
            'reach_id' => reach, 'source_url' => Catalog::MODEL, 'municipalities' => HALLS }
        end
      end

      def geojson
        envelope(type: 'FeatureCollection', features: locations.filter_map do |location|
          next unless location['geometry']

          { type: 'Feature', id: location['id'], geometry: location['geometry'],
            properties: location.except('geometry') }
        end, unlocated: locations.reject { |location| location['geometry'] })
      end

      def records(params = {}, kind: nil)
        RecordPage.new(now: @now, include_coverage: @include_coverage).call(params, kind: kind)
      end

      def series(params)
        AggregatedSeries.new(now: @now, include_coverage: @include_coverage).call(params)
      end

      def evidence(id, revision: nil, cutoff: nil)
        EvidenceDetail.new(now: @now, include_coverage: @include_coverage).call(id, revision: revision, cutoff: cutoff)
      end

      def signals(params = {})
        dataset = Storage.db[params['versions'] == '1' ? :water_signal_versions : :water_signals]
        dataset = signal_filters(dataset, params)
        dataset = dataset.where(kind: params['kind']) if params['kind']
        dataset = dataset.where(signal_key: params['key']) if params['key']
        limit, offset = pagination(params)
        rows = dataset.order(Sequel.desc(:generated_at), :id).limit(limit, offset).all
        total = dataset.count
        envelope(signals: rows.map { |row| public_signal(row) }, total: total,
                 limit: limit, offset: offset, next_offset: offset + limit < total ? offset + limit : nil)
      end

      def signal_evidence(id, params = {})
        signal = Storage.db[:water_signal_versions].where(id: id).first
        raise Error, 'Signal not found' unless signal

        payload = JSON.parse(signal[:payload])
        cutoff = payload.dig('evidence', 'revision_cutoff')
        records = publication_change_revisions(payload)
        return evidence(payload.dig('evidence', 'id')) if payload.dig('evidence', 'id') && !records

        cutoff = payload.dig('evidence', 'revisions').max if records
        return envelope(evidence: payload['evidence'], window: payload['window']) unless cutoff

        records ||= signal_revisions(payload, cutoff)
        limit, offset = pagination(params)
        envelope(records: records.order(:id).limit(limit, offset).all.map do |row|
          { revision_id: row[:id], record: JSON.parse(row[:record]), detected_at: row[:detected_at] }
        end, total: records.count, limit: limit, offset: offset, revision_cutoff: cutoff,
                 next_offset: offset + limit < records.count ? offset + limit : nil)
      end

      def export(params)
        data = RecordPage.new(now: @now, include_coverage: false)
                         .call(params.merge('cursor' => params.fetch('cursor', 'start')))
        columns = %w[external_id source_slug kind location_id reach_id parameter value unit method segment status
                     observed_at observed_date time_precision published_at fetched_at source_url parser_version
                     normalization_version policy_version revision_id revision_cutoff
                     original_timezone publication_count eligibility payload]
        csv = CSV.generate do |output|
          output << columns
          data[:records].each do |record|
            output << columns.map { |column| csv_cell(record[column]) }
          end
        end
        [csv, data.slice(:total, :limit, :offset, :next_offset, :next_cursor, :revision_cutoff)]
      end

      def envelope(**values)
        Storage.db.transaction do
          metadata = @include_coverage ? { source_coverage: coverage } : {}
          { waterbody: 'charles', shared_with: HALLS, generated_at: @now,
            processing_enabled: Water.processing_enabled?, presentation_enabled: Water.presentation_enabled?,
            normalization_version: Normalization::VERSION, policy_version: DailySummaries::POLICY_VERSION,
            revision_cutoff: Storage.db[:water_revisions].max(:id) }.merge(metadata).merge(values)
        end
      end

      def methodology
        { version: Signals::METHOD_VERSION, monitoring_start: Water.time(Storage.db[:water_runs].min(:started_at)),
          history: 'Backfill adds observations; it cannot reconstruct revisions or earlier collection reliability.',
          retention: 'Evidence, revisions, and collection history are permanent; HTTP responses are kept for 30 days.',
          gaps: 'Missing intervals after a two-hour allowance for EPA/USGS, four hours for CRWA predictions. ' \
                'Failed muni checks are tracked separately.',
          shifts: 'Three complete local-day medians beyond 3 × (1.4826 × MAD) of the preceding 28 days. ' \
                  'Requires 80% daily coverage and 21 baseline days; zero dispersion suppresses classification.',
          interpretation: 'CRWA predictions describe boating conditions. Buoy readings describe the buoy location. ' \
                          'Measurements and automated signals do not establish swimming safety or pollution causes.' }
      end

      private

      def public_signal(row)
        payload = JSON.parse(row[:payload])
        # Historical signals may predate redaction at collection time.
        payload['error'] = Muni::Status.public_error(payload['error']) if payload.key?('error')
        row.merge(payload: payload)
      end

      def publication_change_revisions(payload)
        id = payload.dig('evidence', 'id')
        pair = payload.dig('evidence', 'revisions')
        return unless id && pair.is_a?(Array) && !pair.empty?

        Storage.db[:water_revisions].where(evidence_id: id, id: pair)
      end

      def signal_revisions(payload, cutoff)
        revision_ids = payload.dig('evidence', 'revision_ids')
        return Storage.db[:water_revisions].where(id: revision_ids) if revision_ids.is_a?(Array) && !revision_ids.empty?

        versions = Storage.db[:water_revisions].where { id <= cutoff }
        latest = versions.group(:evidence_id).select { max(Sequel[:id]).as(:id) }
        records = Storage.db[:water_revisions].where(id: latest)
        payload.fetch('selector').merge('source_slug' => payload['source_slug']).each do |field, value|
          records = records.where(Sequel.function(:json_extract, :record, "$.#{field}") => value)
        end
        start = Clock.eastern(payload.dig('window', 'baseline_start')).iso8601
        finish = Clock.eastern(Date.parse(payload.dig('window', 'comparison_end')) + 1).iso8601
        records.where(Sequel.lit("json_extract(record, '$.observed_at') >= ?", start))
               .where(Sequel.lit("json_extract(record, '$.observed_at') < ?", finish))
      end

      def signal_filters(dataset, params)
        if params['source'] && !params['source'].empty?
          dataset = dataset.where(Sequel.lit("json_extract(payload, '$.source_slug') = ?", params['source']))
        end
        location = "COALESCE(json_extract(payload, '$.selector.location_id'), " \
                   "json_extract(payload, '$.after.location_id'))"
        dataset = dataset.where(Sequel.lit("#{location} = ?", params['location'])) if params['location']
        if params['reach']
          ids = locations.select { |row| row['reach_id'] == params['reach'] }.map { |row| row['id'] }
          dataset = dataset.where(Sequel.lit(location) => ids)
        end
        stamp = "COALESCE(json_extract(payload, '$.window.comparison_end'), " \
                "json_extract(payload, '$.window.start'), json_extract(payload, '$.window.detected_at'))"
        if params['from']
          dataset = dataset.where(Sequel.lit("#{stamp} >= ?",
                                             filter_time(params['from']).iso8601[0, 10]))
        end
        dataset = dataset.where(Sequel.lit("#{stamp} < ?", filter_time(params['to']).iso8601)) if params['to']
        dataset
      end

      def public_record(row)
        record = row && Eligibility.project(Storage.decode(row)).except('raw')
        return unless record

        decorate_record(record)
      end

      def decorate_record(record)
        definition = Catalog.definitions[record['source_slug'].delete_prefix(PREFIX)]
        observed = Water.time(record['observed_at'])
        record['freshness'] = if definition && definition[:interval] && observed
                                @now - observed > definition[:grace] ? 'stale' : 'current'
                              else
                                'see_source_coverage'
                              end
        @source_checks ||= {}
        record['last_source_check_at'] = @source_checks.fetch(record['source_slug']) do |slug|
          @source_checks[slug] = Storage.checkpoint_fields(slug, ['last_success_at'])['last_success_at']
        end
        if record['kind'] == 'official_advisory'
          expiry = Water.time(record.dig('payload', 'expires_at'))
          record['expiry_state'] =
            expiry && expiry < @now ? 'expired; no all clear inferred' : 'expiry not reached or unknown'
        end
        record
      end

      def filtered(params, dataset: Storage.evidence)
        if params['kinds'] && !params['kinds'].empty?
          kinds = params['kinds'].split(',')
          allowed = %w[sensor derived_sensor gauge laboratory prediction program_state discharge official_advisory]
          raise Error, 'Invalid evidence kinds' unless kinds.all? { |kind| allowed.include?(kind) }

          dataset = dataset.where(kind: kinds)
        end
        { 'location' => :location_id, 'reach' => :reach_id, 'source' => :source_slug,
          'parameter' => :parameter, 'kind' => :kind, 'unit' => :unit, 'method' => :method,
          'segment' => :segment }.each do |key, column|
          dataset = dataset.where(column => params[key]) if params[key] && !params[key].empty?
        end
        date_filtered(dataset, params)
      end

      def date_filtered(dataset, params)
        if params['from']
          from = filter_time(params['from'])
          date = Clock.day(from).to_s
          condition = '(julianday(observed_at) >= julianday(?) OR ' \
                      '(observed_at IS NULL AND observed_date >= ?))'
          dataset = dataset.where(Sequel.lit(condition, from, date))
        end
        if params['to']
          to = filter_time(params['to'])
          date = Clock.day(to).to_s
          date = (Date.parse(date) + 1).to_s unless to == Clock.eastern(date)
          condition = '(julianday(observed_at) < julianday(?) OR ' \
                      '(observed_at IS NULL AND observed_date < ?))'
          dataset = dataset.where(Sequel.lit(condition, to, date))
        end
        dataset
      end

      def filter_time(value)
        value.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? Clock.eastern(value) : Time.iso8601(value)
      rescue ArgumentError
        raise Error, 'Dates must be ISO 8601 timestamps or YYYY-MM-DD local dates'
      end

      def pagination(params)
        limit = Integer(params.fetch('limit', 500))
        offset = Integer(params.fetch('offset', 0))
        raise Error, 'limit must be 1–5000; offset must be nonnegative' unless limit.between?(1, 5000) && offset >= 0

        [limit, offset]
      rescue ArgumentError
        raise Error, 'Pagination must be an integer'
      end

      def csv_cell(value)
        value = Water.json(value) if value.is_a?(Hash) || value.is_a?(Array)
        # Prevent spreadsheet formula execution in publisher-supplied text.
        value.is_a?(String) && value.match?(/\A[=+@\t\r-]/) ? "'#{value}" : value
      end
    end
  end
end
