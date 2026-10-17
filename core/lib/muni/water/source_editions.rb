module Muni
  module Water
    # Publisher clocks and first-observed changes are different evidence. Neither
    # is a promised publication schedule or a substitute for observation time.
    class SourceEditions
      def self.batch_identity(slug, adapter, records)
        requests = if adapter.client.respond_to?(:requested_urls)
                     adapter.client.requested_urls
                   else
                     adapter.client.responses.map { |row| row[:url] }
                   end
        parser = Water.hash([VERSION, Normalization::VERSION])
        query = Water.hash([slug, requests.uniq.sort])
        { query_signature: query, parser_signature: parser, signature: Water.hash([query, parser]),
          source_edition: Water.json(advance(slug, adapter, records)) }
      end

      def self.advance(slug, adapter, records)
        previous = adapter.checkpoint.fetch('publisher_observations', {})
        url = Catalog.definitions.fetch(slug.delete_prefix(PREFIX)).fetch(:url)
        response = adapter.client.responses.reverse.find { |row| row[:url].split('?').first == url }
        stamp = publisher_time(slug, adapter, response, records)
        candidate = if stamp
                      { 'edition' => stamp.iso8601(6), 'changed_at' => stamp.iso8601(6),
                        'basis' => 'publisher_timestamp' }
                    elsif response
                      { 'edition'    => Digest::SHA256.hexdigest(response[:body]),
                        'changed_at' => Water.time(response[:retrieved_at]).iso8601(6),
                        'basis'      => 'first_observed_body_change' }
                    end
        return previous unless candidate
        return previous if candidate['edition'] == previous['edition']

        advance_candidate(previous, candidate)
      end

      def self.publisher_time(slug, adapter, response, records)
        metadata = Water.canonical(adapter.metadata)
        stamp = Water.time(metadata['source_last_edited_at'])
        stamp ||= Water.time(response && response[:headers]['last-modified'])
        stamp ||= records.filter_map { |row| Water.time(row[:published_at]) }.max if slug == "#{PREFIX}usgs"
        stamp
      end

      def self.advance_candidate(previous, candidate)
        prior = Water.time(previous['changed_at']) if previous['basis'] == candidate['basis']
        current = Water.time(candidate['changed_at'])
        return previous if prior && current <= prior

        intervals = prior ? Array(previous['intervals_seconds']) + [current - prior] : []
        intervals = intervals.last(20)
        candidate.merge('intervals_seconds'       => intervals,
                        'median_interval_seconds' => intervals.empty? ? nil : intervals.sort[intervals.length / 2],
                        'edition_count'           => previous.fetch('edition_count', 0) + 1)
      end
    end
  end
end
