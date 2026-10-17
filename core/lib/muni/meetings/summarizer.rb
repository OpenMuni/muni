require 'json'
require 'net/http'
require 'stringio'
require 'uri'
require 'nokogiri'
require 'muni/anthropic_client'

module Muni
  module Meetings
    # Builds a Claude summary + key topics for Meeting records that don't have
    # one yet. Source text, in priority order: the verbatim broadcast captions
    # (WebVTT, for televised bodies like City Council), then the minutes PDF,
    # then the agenda PDF. Bounded and resumable: only fills rows missing a
    # summary, N at a time, and skips anything it can't read.
    module Summarizer
      GRANICUS_BASE = 'https://cambridgema.granicus.com'.freeze
      MAX_FETCH_BYTES = 20 * 1024 * 1024 # cap PDF/caption downloads (OOM guard)
      MAX_SOURCE_CHARS = 40_000          # chars of source text fed to the model
      MAX_EXCERPT_CHARS = 8_000          # bounded text persisted for Ask grounding
      MIN_TEXT_CHARS = 200               # below this there's nothing worth summarizing
      MIN_CAPTION_CHARS = 500            # an empty/near-empty VTT means "not captioned"
      MAX_PDF_PAGES = 80
      USER_AGENT = 'muni.fyi/meetings (+hello@muni.fyi)'.freeze
      SOURCE_PRIORITY = {
        'agenda'        => 1,
        'packet'        => 2,
        'final_actions' => 3,
        'minutes'       => 4,
        'transcript'    => 5
      }.freeze
      FORMAT_PRIORITY = { 'pdf' => 3, 'html' => 2, 'word' => 1 }.freeze

      module_function

      def summarize_pending(hall: 'cambridge', limit: 5, client: Muni::AnthropicClient.new,
                            force: false, since: nil, body: nil)
        return { summarized: 0, skipped: 0, candidates: 0, error: 'AI unavailable' } unless client.configured?

        rows = candidates(hall: hall, force: force, since: since, body: body, limit: limit)
        tally = { summarized: 0, skipped: 0, candidates: rows.size, error: nil }
        rows.each do |row|
          summarize_record?(row, client) ? (tally[:summarized] += 1) : (tally[:skipped] += 1)
        rescue StandardError => e
          tally[:skipped] += 1
          Muni::Logger.instance.warn("Meetings summarizer: #{row.external_id} failed: #{e.class}: #{e.message}")
        end
        tally
      end

      def candidates(hall:, force:, since:, body:, limit:)
        rows = Muni::Store.query(Muni::Records::Meeting, hall: hall, since: since, limit: 500)
        rows = rows.select { |r| summary_candidate?(r, force: force) } unless force
        rows = rows.select { |r| r.body == body } if body && !body.to_s.empty?
        lim = limit.to_i
        lim.positive? ? rows.first(lim) : rows
      end

      def summary_candidate?(row, force:)
        return true if force
        return true if row.ai_summary.to_s.strip.empty?
        return false if row.source_text_kind.to_s.strip.empty?

        source_rank(best_available_source(row, include_granicus_transcript: false)) >
          source_rank(row.source_text_kind)
      end

      def summarize_record?(row, client)
        text, kind = source_text(row)
        return false if text.nil? || text.strip.length < MIN_TEXT_CHARS
        return false if row.ai_summary.to_s.strip != '' && source_rank(kind) <= source_rank(row.source_text_kind)

        excerpt = text.strip[0, MAX_SOURCE_CHARS]
        result = client.complete(
          system:     system_prompt,
          messages:   [{ role: 'user', content: user_prompt(row, excerpt) }],
          max_tokens: 3000
        )
        parsed = parse_summary(result[:text])
        return false if parsed[:summary].to_s.strip.empty?

        persist!(row, parsed, kind, excerpt, result[:model])
        true
      end

      def persist!(row, parsed, kind, excerpt, model)
        row.ai_summary = parsed[:summary]
        row.key_topics = parsed[:key_topics]
        row.source_text_kind = kind
        row.source_excerpt = excerpt[0, MAX_EXCERPT_CHARS]
        row.summary_model = model
        row.summary_generated_at = Time.now.utc
        Muni::Store.upsert(row)
      end

      # ---- source text: transcript -> minutes -> final actions -> packet -> agenda ----

      # Cambridge live-captions its televised meetings (City Council), and the
      # verbatim caption track is a WebVTT at /videos/<clip_id>/captions.vtt — a
      # real transcript, no ASR required. Non-broadcast bodies (BZA, committees)
      # have an empty VTT, so they fall back to the official minutes/agenda PDFs.
      def source_text(row)
        source_candidates(row).each do |candidate|
          text = source_candidate_text(candidate)
          return [text, candidate[:kind]] if text && text.strip.length >= MIN_TEXT_CHARS
        end

        [nil, nil]
      end

      def source_candidates(row, include_granicus_transcript: true)
        candidates = []
        if include_granicus_transcript && row.clip_id
          candidates << { kind: 'transcript', format: 'vtt', url: row.transcript_url, clip_id: row.clip_id }
        end
        documents = document_candidates(row)
        candidates.concat(documents)
        if row.minutes_url && !post_meeting_document?(documents)
          candidates << { kind: 'minutes', format: 'pdf', url: row.minutes_url }
        end
        if row.agenda_url && !agenda_document?(documents)
          candidates << { kind: 'agenda', format: 'pdf', url: row.agenda_url }
        end
        candidates
          .select { |candidate| candidate[:url] || candidate[:clip_id] }
          .sort_by { |candidate| [-source_rank(candidate[:kind]), -format_rank(candidate[:format])] }
      end

      def document_candidates(row)
        Array(row.documents).filter_map do |document|
          kind = document['kind'] || document[:kind]
          url = document['url'] || document[:url]
          next unless source_rank(kind).positive? && url

          { kind: kind, format: document['format'] || document[:format], url: url }
        end
      end

      def post_meeting_document?(documents)
        documents.any? { |document| %w[minutes final_actions].include?(document[:kind].to_s) }
      end

      def agenda_document?(documents)
        documents.any? { |document| %w[agenda packet].include?(document[:kind].to_s) }
      end

      def source_candidate_text(candidate)
        case candidate[:kind]
        when 'transcript'
          caption_text(candidate[:clip_id])
        else
          candidate[:format].to_s == 'html' ? html_text(candidate[:url]) : pdf_text(candidate[:url])
        end
      end

      def best_available_source(row, include_granicus_transcript: true)
        source_candidates(row, include_granicus_transcript: include_granicus_transcript).first&.[](:kind)
      end

      def source_rank(kind)
        SOURCE_PRIORITY.fetch(kind.to_s, 0)
      end

      def format_rank(format)
        FORMAT_PRIORITY.fetch(format.to_s, 0)
      end

      # Fetch + clean the Granicus broadcast caption track. Returns nil when the
      # clip is not captioned (empty VTT) or captions are not processed yet.
      def caption_text(clip_id)
        return nil if clip_id.nil?

        text = strip_vtt(fetch_text("#{GRANICUS_BASE}/videos/#{clip_id}/captions.vtt"))
        text && text.length >= MIN_CAPTION_CHARS ? text : nil
      end

      # WebVTT -> plain transcript: drop the header, NOTE blocks, cue numbers,
      # timestamp lines, and inline tags, then collapse the repeated lines that
      # rolling live-captions emit as text scrolls.
      def strip_vtt(raw)
        return nil if raw.to_s.strip.empty?

        lines = []
        raw.to_s.gsub(/<[^>]+>/, '').each_line do |line|
          text = line.strip
          next if text.empty? || text == 'WEBVTT' || text.start_with?('NOTE')
          next if text.include?('-->') || text.match?(/\A\d+\z/)
          next if lines.last == text

          lines << text
        end
        cleaned = lines.join(' ').gsub(/\s+/, ' ').strip
        cleaned.empty? ? nil : cleaned
      end

      def pdf_text(url)
        bytes = fetch_binary(url)
        return nil if bytes.nil? || bytes.empty?

        extract_pdf(bytes)
      end

      def html_text(url)
        raw = fetch_text(url)
        return nil if raw.to_s.empty?

        doc = Nokogiri::HTML(raw)
        doc.css('script, style, noscript').remove
        cleaned = doc.text.gsub(/[ \t]+/, ' ').gsub(/\n{3,}/, "\n\n").strip
        cleaned.empty? ? nil : cleaned
      end

      def extract_pdf(bytes)
        require 'pdf/reader'
        reader = PDF::Reader.new(StringIO.new(bytes))
        text = reader.pages.first(MAX_PDF_PAGES).map(&:text).join("\n")
        cleaned = text.gsub(/[ \t]+/, ' ').gsub(/\n{3,}/, "\n\n").strip
        cleaned.empty? ? nil : cleaned
      rescue LoadError
        Muni::Logger.instance.warn('Meetings summarizer: pdf-reader gem missing; cannot extract PDF text')
        nil
      rescue StandardError => e
        Muni::Logger.instance.warn("Meetings summarizer: PDF parse failed: #{e.class}: #{e.message}")
        nil
      end

      # ---- prompts ----

      def system_prompt
        <<~PROMPT.strip
          You summarize official municipal meeting documents (agendas and minutes) for
          residents. Be factual and neutral; never invent votes, names, or outcomes that
          are not in the text. Plain text only — no markdown.

          Respond with a single JSON object and nothing else:
          {"summary": "<2-4 sentence plain-language summary of what this meeting covered and decided>",
           "key_topics": ["<short topic>", "..."]}
          Use at most 6 key_topics. If the document is an agenda or packet without outcomes,
          summarize what is scheduled to be discussed and say so.
        PROMPT
      end

      def user_prompt(row, excerpt)
        meeting_at = row.meeting_at.respond_to?(:strftime) ? row.meeting_at.strftime('%B %-d, %Y') : row.meeting_at
        <<~PROMPT
          Meeting: #{row.title}
          Body: #{row.body}
          Date: #{meeting_at}

          Document text (may be truncated):
          #{excerpt}
        PROMPT
      end

      def parse_summary(text)
        json = text.to_s[/\{.*\}/m]
        data = json ? JSON.parse(json) : {}
        {
          summary:    data['summary'].to_s.strip,
          key_topics: Array(data['key_topics']).map { |t| t.to_s.strip }.reject(&:empty?).first(6)
        }
      rescue JSON::ParserError
        # Model didn't return JSON — fall back to using the raw text as the summary.
        { summary: text.to_s.strip[0, 1_000], key_topics: [] }
      end

      # ---- HTTP that follows redirects (the shared Faraday client does not) ----

      def fetch_text(url)
        status, body = raw_get(url)
        status == :ok ? body : nil
      end

      def fetch_binary(url)
        status, body = raw_get(url)
        status == :ok ? body : nil
      end

      def raw_get(url, limit: 5)
        return [:error, nil] if url.to_s.empty? || limit <= 0

        uri = URI(url)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                        open_timeout: 15, read_timeout: 90) do |http|
          req = Net::HTTP::Get.new(uri)
          req['User-Agent'] = USER_AGENT
          req['Accept'] = '*/*'
          http.request(req) { |res| return handle_response(res, uri, limit) }
        end
      rescue StandardError => e
        Muni::Logger.instance.warn("Meetings summarizer: fetch error #{url}: #{e.class}: #{e.message}")
        [:error, nil]
      end

      def handle_response(res, uri, limit)
        case res
        when Net::HTTPRedirection
          location = res['location'].to_s
          location = (uri + location).to_s unless location.start_with?('http')
          raw_get(location, limit: limit - 1)
        when Net::HTTPSuccess
          read_capped_body(res)
        else
          [:error, nil]
        end
      end

      def read_capped_body(res)
        declared = res['content-length'].to_i
        return [:too_big, nil] if declared.positive? && declared > MAX_FETCH_BYTES

        buffer = +''
        res.read_body do |chunk|
          buffer << chunk
          return [:too_big, nil] if buffer.bytesize > MAX_FETCH_BYTES
        end
        [:ok, buffer]
      end
    end
  end
end
