module Muni
  module Water
    # Cursor pages read one immutable revision boundary, including group membership.
    class RecordPage < Query
      # Immutable revisions expose UTC timestamps at whole-second precision.
      ORDER_DATE = "COALESCE(strftime('%Y-%m-%dT%H:%M:%SZ', observed_at), observed_date, '')".freeze

      def call(params = {}, kind: nil)
        Storage.db.transaction { snapshot_page(params, kind: kind) }
      end

      def snapshot_page(params, kind:)
        @source_checks = {}
        @params = params
        @cursor = decode_cursor
        @revision_cutoff = @cursor ? @cursor['cutoff'] : Storage.db[:water_revisions].max(:id) || 0
        @snapshot = @cursor ? RecordProjection.snapshot(@cursor.fetch('cutoff')) : Storage.evidence
        columns = %i[external_id source_slug kind location_id reach_id parameter unit method segment
                     observed_at observed_date publication_group_id]
        index = @cursor ? RecordProjection.snapshot(@revision_cutoff, columns: columns) : Storage.evidence
        dataset = filtered(params, dataset: index)
        dataset = dataset.where(kind: kind) if kind
        @presentation = params.fetch('presentation', params.fetch('view', 'publications'))
        unless %w[observations publications].include?(@presentation)
          raise Error, 'presentation must be observations or publications'
        end

        page(observations(dataset))
      end

      private

      def observations(dataset)
        return dataset unless @presentation == 'observations'

        representatives = dataset.select { min(external_id).as(:external_id) }
                                 .group(Sequel.lit('COALESCE(publication_group_id, external_id)'))
        dataset.where(external_id: representatives)
      end

      def page(dataset)
        limit, offset = pagination(@params)
        total = dataset.count
        if @cursor && @cursor['last_id']
          dataset = dataset.where(Sequel.lit("#{ORDER_DATE} < ? OR " \
                                             "(#{ORDER_DATE} = ? AND external_id > ?)",
                                             @cursor['last_date'], @cursor['last_date'], @cursor['last_id']))
          offset = 0
        end
        rows = dataset.select(:external_id, Sequel.lit(ORDER_DATE).as(:cursor_date))
                      .order(Sequel.desc(Sequel.lit(ORDER_DATE)), :external_id)
                      .limit(limit + 1, offset).all
        more = rows.length > limit
        rows = rows.first(limit)
        evidence = @snapshot.where(external_id: rows.map { |row| row[:external_id] }).all
                            .to_h { |row| [row[:external_id], row] }
        projected = rows.map { |row| public_record(evidence.fetch(row[:external_id])) }
        RecordProjection.attach(projected, cutoff: @revision_cutoff, dataset: @snapshot)
        RecordProjection.attach_publications(projected, dataset: @snapshot) if @presentation == 'observations'
        envelope(records: projected, total: total, limit: limit, offset: offset, presentation: @presentation,
                 next_offset: more ? offset + limit : nil, next_cursor: more ? next_cursor(rows.last) : nil,
                 revision_cutoff: @revision_cutoff)
      end

      def next_cursor(last)
        return unless @cursor && last

        value = @cursor.merge('last_date' => last[:cursor_date],
                              'last_id'   => last[:external_id])
        Base64.urlsafe_encode64(JSON.generate(value))
      end

      def cursor_signature
        Water.hash(@params.except('cursor', 'limit', 'offset', 'include_coverage'))
      end

      def validate_position(cursor)
        return unless cursor.key?('last_id') || cursor.key?('last_date')

        if cursor['last_id'].is_a?(String) && cursor['last_date'].is_a?(String)
          date = cursor['last_date']
          unless date.empty? || date.match?(/\A\d{4}-\d{2}-\d{2}\z/)
            parsed = Water.time(date) || raise(Error, 'Invalid export cursor position')
            cursor['last_date'] = parsed.iso8601
          end
          return
        end

        raise Error, 'Invalid export cursor position'
      end

      def decode_cursor
        return unless @params['cursor']
        if @params['cursor'] == 'start'
          return { 'cutoff'  => Storage.db[:water_revisions].max(:id) || 0,
                   'filters' => cursor_signature }
        end

        cursor = JSON.parse(Base64.urlsafe_decode64(@params['cursor']))
        raise Error, 'Invalid export cursor' unless cursor.is_a?(Hash)
        raise Error, 'Cursor does not match the requested filters' unless cursor['filters'] == cursor_signature
        raise Error, 'Invalid revision cutoff' unless cursor['cutoff'].is_a?(Integer) && cursor['cutoff'] >= 0

        validate_position(cursor)
        cursor
      rescue JSON::ParserError, ArgumentError
        raise Error, 'Invalid export cursor'
      end
    end
  end
end
