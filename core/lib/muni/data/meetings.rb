require 'time'
require 'sequel'

module Muni
  module Data
    module Meetings
      extend self

      PRIMEGOV_FETCH_LIMIT = 200
      BODY_PATTERNS = [
        [/city council/i, 'City Council'],
        [/planning board/i, 'Planning Board'],
        [/ordinance committee/i, 'Ordinance Committee'],
        [/board of zoning appeal|zoning/i, 'Board of Zoning Appeal'],
        [/school committee/i, 'School Committee'],
        [/committee/i, 'Committee']
      ].freeze

      def call(hall:, limit:)
        rows = Muni::Data.records_for_type('meetings', hall: hall, limit: limit)
        materialized_ids = rows.map { |row| field_value(row, :external_id) }.compact.to_set
        rows += primegov_meetings(hall: hall, limit: limit).reject do |row|
          materialized_ids.include?(field_value(row, :external_id))
        end
        dedupe(rows)
          .sort_by { |row| sort_time(row) || Time.at(0).utc }
          .reverse
          .first(limit)
      end

      private

      def primegov_meetings(hall:, limit:)
        source_slug = "#{hall}/primegov_meetings"
        Muni::Store.query(
          Muni::Records::DigestItem,
          hall:        hall,
          source_slug: source_slug,
          item_type:   'public_meeting',
          limit:       primegov_fetch_limit(limit)
        ).map { |row| primegov_payload(row) }
      rescue Sequel::DatabaseError
        []
      end

      def primegov_fetch_limit(limit)
        (limit * 3).clamp(limit, [limit, PRIMEGOV_FETCH_LIMIT].max)
      end

      def primegov_payload(row)
        metadata = row.metadata || {}
        documents = Array(metadata['documents'])
        starts_at = row.event_start_at || row.published_at || row.fetched_at
        {
          external_id:    row.external_id,
          hall:           row.hall,
          source_slug:    row.source_slug,
          body:           body_for(row.title),
          title:          row.title,
          meeting_at:     iso_time(starts_at),
          agenda_url:     document_url(documents, %w[agenda]) || row.url,
          minutes_url:    document_url(documents, %w[minutes final_actions]),
          video_url:      metadata['video_url'],
          source_url:     row.url,
          source_excerpt: row.summary,
          documents:      documents,
          key_topics:     [],
          people:         [],
          collected_at:   iso_time(row.collected_at),
          last_seen_at:   iso_time(row.last_seen_at)
        }.compact
      end

      def body_for(title)
        match = BODY_PATTERNS.find { |pattern, _body| title.to_s.match?(pattern) }
        match ? match.last : 'Public Meeting'
      end

      def dedupe(rows)
        rows
          .group_by { |row| dedupe_key(row) }
          .values
          .map { |group| group.max_by { |row| payload_score(row) } }
      end

      def dedupe_key(row)
        %i[body title meeting_at].map { |field| field_value(row, field).to_s.downcase.strip }.join('|')
      end

      def payload_score(row)
        %i[clip_id ai_summary documents video_url].map { |field| field_value(row, field) ? 1 : 0 }
      end

      def sort_time(row)
        value = field_value(row, :meeting_at)
        value.is_a?(Time) ? value : Time.parse(value.to_s)
      rescue ArgumentError
        nil
      end

      def field_value(row, field)
        row[field] || row[field.to_s]
      end

      def document_url(documents, kinds)
        document = Array(documents).find do |document|
          Array(kinds).include?(document['kind'] || document[:kind])
        end
        document && (document['url'] || document[:url])
      end

      def iso_time(value)
        value.respond_to?(:utc) ? value.utc.iso8601 : value
      end
    end
  end
end
