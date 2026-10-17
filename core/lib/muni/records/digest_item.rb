require 'muni/record'

module Muni
  module Records
    class DigestItem < Muni::Record
      schema do
        string  :external_id, primary: true
        string  :hall
        string  :source_slug
        string  :source_name
        string  :source_type
        string  :item_type
        string  :section_hint
        string  :title
        text    :summary
        string  :category
        string  :url
        time    :published_at
        time    :event_start_at
        time    :event_end_at
        time    :updated_at
        time    :fetched_at
        time    :first_seen_at
        time    :last_seen_at
        time    :last_digest_at
        string  :location_name
        string  :neighborhood
        point   :location
        json    :tags
        float   :confidence
        float   :freshness_score
        string  :dedupe_key, indexed: true
        json    :metadata
        time    :collected_at
      end

      def metadata
        attributes[:metadata] || {}
      end

      def metadata=(value)
        attributes[:metadata] = value
      end
    end
  end
end
