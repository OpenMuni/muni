require 'nokogiri'
require_relative '_civic_page'

module Cambridge
  # Scrapes the Cambridge Granicus archive (ViewPublisher) into Meeting records.
  #
  # The listing is an HTML table: each meeting is a <tr> whose row-header cell
  # reads "<Mon D, YYYY H:MM PM> - <Body> - <subtype>", with separate Date and
  # Duration cells and Agenda/Minutes/MediaPlayer links carrying ?clip_id=N.
  # Cambridge does not expose text transcripts (TranscriptViewer is a stub) and
  # agenda/minutes are PDFs, so this source only captures metadata + document
  # links — Muni::Meetings::Summarizer fetches a PDF later to build the summary.
  class Meetings < Muni::Source
    include Cambridge::CivicPage

    source :meetings,
           hall:     'cambridge',
           emits:    Muni::Records::Meeting,
           base_url: 'https://cambridgema.granicus.com'

    VIEW_ID = 1
    # The bodies we surface for the MVP. Operators can widen this via the CLI.
    DEFAULT_BODIES = ['City Council', 'Board of Zoning Appeal', 'Charter Review Committee'].freeze
    # Don't ingest meetings older than this unless an explicit `since` is given.
    DEFAULT_FLOOR = Time.utc(2025, 1, 1).freeze
    GRANICUS_BASE = 'https://cambridgema.granicus.com'.freeze
    COUNCIL_PATH = '/departments/citycouncil/members'.freeze
    # Granicus mixes UTF-8 and Windows-1252 punctuation in the same page, so map the
    # common CP1252 bytes (en/em dashes, smart quotes) to UTF-8 before scrubbing.
    CP1252 = {
      "\x91".b => '‘'.b, "\x92".b => '’'.b, "\x93".b => '“'.b, "\x94".b => '”'.b,
      "\x96".b => '–'.b, "\x97".b => '—'.b, "\x85".b => '…'.b, "\xA0".b => ' '.b
    }.freeze

    def initialize(opts = {})
      super
      @bodies = Array(opts[:bodies]).map(&:to_s).reject(&:empty?)
      @bodies = DEFAULT_BODIES if @bodies.empty?
    end

    def pull(since: nil, limit: 60)
      floor = time_value(since) || DEFAULT_FLOOR
      doc = granicus_doc
      records = doc.css('tr').filter_map { |row| meeting_from_row(row, floor) }
      dedupe(records).sort_by { |r| r.meeting_at || Time.at(0).utc }.reverse
                     .first(limit.to_i.positive? ? limit.to_i : records.length)
    end

    def cursor_time(record)
      record.meeting_at
    end

    private

    # The ViewPublisher archive is a 3 MB+ table whose markup defeats libxml2
    # (it collapses to ~10 <tr>). The HTML5 parser recovers all rows.
    def granicus_doc
      Nokogiri::HTML5.parse(normalize_encoding(http.get_raw('/ViewPublisher.php', { view_id: VIEW_ID })))
    end

    def normalize_encoding(raw)
      bytes = raw.to_s.b
      CP1252.each { |from, to| bytes = bytes.gsub(from, to) }
      bytes.force_encoding('UTF-8').scrub('')
    end

    def meeting_from_row(row, floor)
      urls = viewer_urls(row)
      clip_id = urls.join(' ')[/clip_id=(\d+)/, 1]
      return nil unless clip_id

      name = node_text(row.at_css('[scope="row"]')) || node_text(row)
      return nil unless name

      body = @bodies.find { |b| name.include?(b) }
      return nil unless body

      meeting_at = meeting_time(row, name)
      return nil unless meeting_at
      return nil if meeting_at < floor

      emit(meeting_attrs(urls, clip_id, name, body, meeting_at, row))
    end

    def meeting_attrs(urls, clip_id, name, body, meeting_at, row)
      {
        external_id:    "cambridge/meetings/#{clip_id}",
        hall:           'cambridge',
        source_slug:    self.class.slug,
        body:           body,
        title:          meeting_title(name, body),
        meeting_at:     meeting_at,
        clip_id:        clip_id.to_i,
        duration:       duration_text(row),
        agenda_url:     pick_url(urls, 'AgendaViewer.php'),
        minutes_url:    pick_url(urls, 'MinutesViewer.php'),
        video_url:      pick_url(urls, 'MediaPlayer.php'),
        transcript_url: "#{GRANICUS_BASE}/videos/#{clip_id}/captions.vtt",
        source_url:     pick_url(urls, 'MediaPlayer.php') || pick_url(urls, 'AgendaViewer.php') ||
          "#{GRANICUS_BASE}/ViewPublisher.php?view_id=#{VIEW_ID}",
        people:         body == 'City Council' ? council_roster : []
      }
    end

    # Viewer links live in either href or onclick attributes, so scan the row's
    # raw HTML rather than just <a href>.
    def viewer_urls(row)
      row.inner_html.to_s
         .scan(/(?:AgendaViewer|MinutesViewer|MediaPlayer|TranscriptViewer)\.php\?[^"'\s)]+/)
         .map { |u| u.gsub('&amp;', '&') }.uniq
    end

    def pick_url(urls, token)
      path = urls.find { |u| u.start_with?(token) }
      path && "#{GRANICUS_BASE}/#{path}"
    end

    # "<Body> - <subtype>" with the leading "<date time> - " stripped off.
    def meeting_title(name, body)
      stripped = name.split(/\s[-–]\s/, 2)[1]
      title = clean_text(stripped) || clean_text(name)
      title&.include?(body) ? title : [body, title].compact.uniq.join(' - ')
    end

    def meeting_time(row, name)
      cell = cell_for(row, 'Date')
      if cell
        date_part, time_part = node_text(cell).to_s.split(/\s[-–]\s/, 2)
        parsed = local_date_time(date_part, time_part)
        return parsed if parsed
      end
      # Fall back to the datetime embedded in the row-header name.
      local_date_time(first_date_text(name), first_time_text(name))
    end

    def duration_text(row)
      cell = cell_for(row, 'Duration')
      cell && clean_text(node_text(cell))
    end

    def cell_for(row, header)
      row.css('td, th').find { |cell| cell['headers'].to_s.split(/\s+/).first == header }
    end

    def dedupe(records)
      seen = {}
      records.filter_map do |record|
        key = record.external_id
        next if key.nil? || seen[key]

        seen[key] = true
        record
      end
    end

    # ---- council roster (best-effort "people involved") ----

    def council_roster
      return @council_roster if defined?(@council_roster)

      @council_roster = fetch_council_roster
    end

    def fetch_council_roster
      doc = Nokogiri::HTML(council_http.get_raw(COUNCIL_PATH))
      table = doc.at_css('table.councilMembersTable') || doc
      table.css('a[href^="mailto:"]').filter_map { |a| council_member(a) }.uniq { |m| m['email'] }
    rescue StandardError => e
      Muni::Logger.instance.warn("Meetings: council roster scrape failed: #{e.class}: #{e.message}")
      []
    end

    def council_member(anchor)
      email = anchor['href'].to_s.sub(/\Amailto:/i, '').strip
      return nil if email.empty? || email.downcase.start_with?('citycouncil@')

      container = anchor.ancestors.find { |n| %w[td li tr].include?(n.name) } || anchor.parent
      text = node_text(container).to_s
      name = clean_text(text[/\A\s*(.*?)\s*\(/, 1])
      return nil unless name&.length&.between?(3, 60)

      { 'name' => name, 'email' => email, 'role' => council_role(text) }
    end

    def council_role(text)
      return 'Vice Mayor' if text.match?(/vice\s*mayor/i)
      return 'Mayor' if text.match?(/\bmayor\b/i)

      'Councillor'
    end

    def council_http
      @council_http ||= Muni::Helpers::Http.new(base_url: Cambridge::CivicPage::CAMBRIDGE_BASE_URL)
    end
  end
end
