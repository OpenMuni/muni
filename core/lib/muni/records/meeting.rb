require 'muni/record'

module Muni
  module Records
    # A municipal public meeting (City Council, Board of Zoning Appeal, etc.)
    # scraped from the Granicus archive. Metadata + document links are filled by
    # the ingest source; `ai_summary`/`key_topics`/`source_excerpt` are filled
    # later by Muni::Meetings::Summarizer (idempotent upsert on external_id).
    class Meeting < Muni::Record
      schema do
        string  :external_id, primary: true # "cambridge/meetings/<clip_id>"
        string  :hall
        string  :source_slug
        string  :body # "City Council" | "Board of Zoning Appeal" | ...
        string  :title
        time    :meeting_at
        integer :clip_id
        string  :duration
        string  :agenda_url
        string  :minutes_url
        string  :transcript_url
        string  :video_url
        string  :source_url
        # --- AI summary (filled by the summarizer) ---
        text    :ai_summary
        string  :summary_model
        time    :summary_generated_at
        string  :source_text_kind            # 'minutes' | 'agenda' | 'transcript'
        text    :source_excerpt              # bounded text fed to the model (truncated)
        json    :key_topics                  # ["Affordable housing overlay", ...]
        json    :people                      # [{name, role, email, photo}]
        json    :documents                   # [{name, kind, format, url, published_at}]
        # --- beat bookkeeping ---
        time    :collected_at
        time    :last_seen_at
      end

      def key_topics
        attributes[:key_topics] || []
      end

      def people
        attributes[:people] || []
      end

      def documents
        attributes[:documents] || []
      end
    end
  end
end
