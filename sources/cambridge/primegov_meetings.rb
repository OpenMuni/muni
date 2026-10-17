require 'json'
require_relative '_civic_page'

module Cambridge
  class PrimegovMeetings < Muni::Source
    include Cambridge::CivicPage

    source :primegov_meetings,
           hall:     'cambridge',
           emits:    Muni::Records::DigestItem,
           base_url: 'https://cambridgema.primegov.com'

    CURRENT_AND_PREVIOUS_YEARS = 2

    def pull(since: nil, limit: 40)
      fetched_at = Time.now.utc
      records = api_records(fetched_at, since) + archived_records(fetched_at, since)
      records = html_records(fetched_at, since) if records.empty?
      ordered = records.sort_by { |record| record.event_start_at || Time.at(0).utc }.reverse
      unique_records(ordered, limit)
    end

    private

    def allow_future_dates?
      true
    end

    def api_records(fetched_at, since)
      data = JSON.parse(http.get_raw('/api/v2/PublicPortal/ListUpcomingMeetings'))
      Array(data).filter_map do |row|
        api_record(row, fetched_at, since)
      end
    rescue JSON::ParserError, Muni::Helpers::Http::Error => e
      Muni::Logger.instance.warn("PrimeGov API fallback: #{e.class}: #{e.message}")
      []
    end

    def archived_records(fetched_at, since)
      archived_years.flat_map do |year|
        data = JSON.parse(http.get_raw('/api/v2/PublicPortal/ListArchivedMeetings', { year: year }))
        Array(data).filter_map { |row| api_record(row, fetched_at, since, archived: true) }
      end
    rescue JSON::ParserError, Muni::Helpers::Http::Error => e
      Muni::Logger.instance.warn("PrimeGov archive fallback: #{e.class}: #{e.message}")
      []
    end

    def archived_years
      current = Time.now.year
      wanted = ((current - (CURRENT_AND_PREVIOUS_YEARS - 1))..current).to_a.reverse
      data = JSON.parse(http.get_raw('/api/v2/PublicPortal/GetArchivedMeetingYears'))
      years = Array(data).map(&:to_i)
      wanted.select { |year| years.include?(year) }
    rescue JSON::ParserError, Muni::Helpers::Http::Error
      wanted
    end

    def api_record(row, fetched_at, _since, archived: false)
      return nil unless row.is_a?(Hash)

      title = clean_text(row['title'])
      starts_at = local_date_time(row['date'], row['time'])
      return nil unless title

      documents = Array(row['documentList'])
      normalized_documents = meeting_documents(documents)
      digest_item(
        external_id:    "#{self.class.slug}/#{row['id']}",
        source_name:    'PrimeGov Meetings',
        source_type:    'official_record',
        item_type:      'public_meeting',
        section_hint:   'civic_decisions',
        title:          title,
        summary:        meeting_summary(row, documents),
        category:       'public meetings',
        url:            row['videoUrl'] || '/public/portal',
        event_start_at: starts_at,
        published_at:   starts_at,
        updated_at:     latest_document_time(normalized_documents),
        fetched_at:     fetched_at,
        tags:           ['meeting', 'agenda', public_comment_tag(row)].compact,
        confidence:     0.94,
        metadata:       meeting_metadata(row, normalized_documents, archived: archived)
      )
    end

    def html_records(fetched_at, since)
      doc = html('/public/portal')
      meeting_nodes(doc).filter_map do |node|
        title = title_from(node) || meeting_title_from_text(node_text(node))
        next unless title

        text = node_text(node)
        starts_at = local_date_time(first_date_text(text), first_time_text(text))
        next if since && starts_at && starts_at < since

        digest_item(
          source_name:    'PrimeGov Meetings',
          source_type:    'official_record',
          item_type:      'public_meeting',
          section_hint:   'civic_decisions',
          title:          title,
          summary:        truncate_text(summary_from(node, title: title) || primegov_notice(doc), 360),
          category:       'public meetings',
          url:            href_from(node) || '/public/portal',
          event_start_at: starts_at,
          published_at:   starts_at,
          fetched_at:     fetched_at,
          tags:           ['meeting', 'agenda', public_comment_tag(text)].compact,
          confidence:     0.9,
          metadata:       {
            agenda_available: text.match?(/agenda|documents/i) || nil,
            public_comment:   text.match?(/public comment|request to speak/i) || nil
          }.compact
        )
      end
    end

    def meeting_nodes(doc)
      table_rows = doc.css('tr').reject { |row| row.css('th').any? }
      table_rows = table_rows.select { |row| node_text(row).to_s.match?(/meeting|council|committee|commission/i) }
      cards = doc.css('.meeting, .meeting-row, .agenda-item, main li').select do |node|
        node_text(node).to_s.match?(/meeting|council|committee|commission/i)
      end
      (table_rows + cards).uniq
    end

    def meeting_title_from_text(text)
      return nil unless text

      line = text.split(%r{Documents|Options|Meeting Type|Date/Time}i).first
      clean_text(line)&.sub(/\ACurrent And Upcoming Meetings\s*/i, '')
    end

    def primegov_notice(doc)
      text = node_text(doc.at_css('main, body'))
      text&.slice(/PLEASE NOTE.*?(?:City Clerk office|$)/i)
    end

    def meeting_summary(row, documents)
      parts = []
      parts << "Scheduled for #{row['date']} at #{row['time']}" if row['date'] && row['time']
      parts << document_summary(documents)
      parts << 'Public comment is enabled.' if row['allowPublicComment'] || row['allowPublicSpeaker']
      truncate_text(parts.compact.join('. '), 360)
    end

    def document_summary(documents)
      names = documents.filter_map { |document| clean_text(document['name'] || document['templateName']) }.uniq
      return nil if names.empty?

      "Documents available: #{names.first(3).join(', ')}"
    end

    def meeting_metadata(row, documents, archived:)
      {
        agenda_available: documents.any? || nil,
        public_comment:   row['allowPublicComment'] || row['allowPublicSpeaker'] || nil,
        document_count:   documents.length,
        documents:        documents,
        primegov_id:      row['id'],
        archived:         archived,
        video_url:        row['videoUrl']
      }.compact
    end

    def meeting_documents(documents)
      documents.filter_map do |document|
        name = clean_text(document['templateName'])
        url = document_url(document)
        next unless name && url

        {
          name:         name,
          kind:         document_kind(name),
          format:       document_format(document['compileOutputType']),
          url:          absolute_url(url),
          published_at: iso_time(time_value(document['publishDate']))
        }.compact
      end
    end

    def document_url(document)
      link = clean_text(document['link'])
      return link if link

      output_type = document['compileOutputType'].to_i
      template_id = document['templateId'].to_i
      meeting_param = if template_id.positive?
                        "meetingTemplateId=#{template_id}"
                      else
                        "compiledMeetingDocumentFileId=#{document['id']}"
                      end
      return "/Portal/Meeting?#{meeting_param}" if output_type == 3

      "/Public/CompiledDocument?#{meeting_param}&compileOutputType=#{output_type}"
    end

    def document_kind(name)
      text = name.to_s.downcase
      return 'minutes' if text.include?('minutes')
      return 'final_actions' if text.match?(/final action|action/)
      return 'packet' if text.include?('packet')
      return 'agenda' if text.include?('agenda')

      'document'
    end

    def document_format(output_type)
      case output_type.to_i
      when 1 then 'pdf'
      when 2 then 'word'
      when 3 then 'html'
      else 'document'
      end
    end

    def latest_document_time(documents)
      documents.filter_map { |document| time_value(document[:published_at] || document['published_at']) }.max
    end

    def iso_time(value)
      value.respond_to?(:utc) ? value.utc.iso8601 : value
    end

    def public_comment_tag(value)
      return 'public comment' if value.is_a?(Hash) && (value['allowPublicComment'] || value['allowPublicSpeaker'])

      'public comment' if value.to_s.match?(/public comment|request to speak/i)
    end
  end
end
