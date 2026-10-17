module Muni
  module Meetings
    module PrimegovMaterializer
      extend self

      SOURCE_SLUG = 'cambridge/primegov_meetings'.freeze
      DEFAULT_LIMIT = 250
      BODY_PATTERNS = [
        [/city council/i, 'City Council'],
        [/planning board/i, 'Planning Board'],
        [/ordinance committee/i, 'Ordinance Committee'],
        [/board of zoning appeal|zoning/i, 'Board of Zoning Appeal'],
        [/school committee/i, 'School Committee'],
        [/committee/i, 'Committee']
      ].freeze
      DOCUMENT_KIND_ORDER = %w[minutes final_actions packet agenda].freeze
      FORMAT_SCORE = { 'pdf' => 3, 'html' => 2, 'word' => 1 }.freeze

      def materialize!(hall: 'cambridge', limit: DEFAULT_LIMIT, now: Time.now.utc)
        rows = digest_rows(hall: hall, limit: limit)
        rows.each { |row| upsert_meeting(row, now: now) }
        { candidates: rows.size, upserted: rows.size }
      end

      private

      def digest_rows(hall:, limit:)
        Muni::Store.query(
          Muni::Records::DigestItem,
          hall:        hall,
          source_slug: SOURCE_SLUG,
          item_type:   'public_meeting',
          limit:       limit,
          order:       :event_start_at
        )
      end

      def upsert_meeting(row, now:)
        existing = Muni::Store.find(Muni::Records::Meeting, row.external_id)
        documents = Array(row.metadata['documents'])
        Muni::Store.upsert(
          Muni::Records::Meeting.new(
            external_id:          row.external_id,
            hall:                 row.hall,
            source_slug:          row.source_slug,
            body:                 body_for(row.title),
            title:                row.title,
            meeting_at:           row.event_start_at || row.published_at,
            agenda_url:           document_url(documents, %w[agenda]) || document_url(documents, %w[packet]) || row.url,
            minutes_url:          document_url(documents, %w[minutes final_actions]),
            video_url:            row.metadata['video_url'] || row.url,
            source_url:           row.url,
            documents:            documents,
            ai_summary:           existing&.ai_summary,
            summary_model:        existing&.summary_model,
            summary_generated_at: existing&.summary_generated_at,
            source_text_kind:     existing&.source_text_kind,
            source_excerpt:       existing&.source_excerpt,
            key_topics:           existing&.key_topics || [],
            people:               existing&.people || [],
            collected_at:         now,
            last_seen_at:         now
          )
        )
      end

      def body_for(title)
        match = BODY_PATTERNS.find { |pattern, _body| title.to_s.match?(pattern) }
        match ? match.last : 'Public Meeting'
      end

      def document_url(documents, kinds)
        document = best_document(documents, kinds)
        document && (document['url'] || document[:url])
      end

      def best_document(documents, kinds)
        wanted = Array(kinds)
        documents
          .select { |document| wanted.include?(document['kind'] || document[:kind]) }
          .max_by { |document| document_score(document) }
      end

      def document_score(document)
        kind = document['kind'] || document[:kind]
        format = document['format'] || document[:format]
        [
          DOCUMENT_KIND_ORDER.length - (DOCUMENT_KIND_ORDER.index(kind) || DOCUMENT_KIND_ORDER.length),
          FORMAT_SCORE.fetch(format.to_s, 0),
          document['published_at'] || document[:published_at].to_s
        ]
      end
    end
  end
end
