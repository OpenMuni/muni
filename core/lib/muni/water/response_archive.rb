module Muni
  module Water
    module ResponseArchive
      module_function

      def prepare(slug, responses, now:)
        responses.map do |response|
          { source_slug: slug, url: response[:url], retrieved_at: response[:retrieved_at] || now,
            digest: Digest::SHA256.hexdigest(response[:body].b), headers: Water.json(response[:headers]),
            final_url: response[:final_url] || response[:url], redirects: Water.json(response[:redirects] || []),
            body: Sequel.blob(Zlib.gzip(response[:body])) }
        end
      end

      def manifest(responses)
        responses.map do |response|
          response.slice(:url, :final_url, :digest).merge(
            retrieved_at: Water.time(response[:retrieved_at]).iso8601(6),
            headers: JSON.parse(response[:headers]), redirects: JSON.parse(response[:redirects])
          )
        end
      end

      # The caller supplies the publication transaction so bodies and evidence commit together.
      def publish(slug, responses, now:)
        responses.each do |response|
          existing = Storage.db[:water_responses].where(source_slug: slug, url: response[:url],
                                                        digest: response[:digest]).select(:id).first
          Storage.db[:water_responses].insert(response) unless existing
        end
        cutoff = now - (30 * 86_400)
        document = "LOWER(url) LIKE '%.pdf%' OR LOWER(COALESCE(headers, '')) LIKE '%application/pdf%'"
        Storage.db[:water_responses].where { retrieved_at < cutoff }.exclude(Sequel.lit(document)).delete
      end
    end
  end
end
