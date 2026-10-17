require 'uri'

module Muni
  module Water
    class Client
      attr_reader :responses, :snapshot_time, :last_retrieved_at, :last_checked_at, :requested_urls

      def initialize(checkpoint = {}, slug: nil, transport: nil)
        @slug = slug
        @validators = checkpoint.fetch('validators', {}).dup
        @responses = []
        @requested_urls = []
        @snapshot_time = Time.now.utc
        @transport = transport || Muni::Helpers::Http.new(base_url: '', headers: { 'Accept' => '*/*' },
                                                          timeout: 30, open_timeout: 10, retries: 0,
                                                          follow_redirects: true)
        @not_modified = false
        prepare_pending if @slug
      end

      def get(url, params = {}, conditional: true, resume: true, binary: false)
        lease = Thread.current[:muni_water_lease]
        ScheduleStore.renew(*lease) if lease
        uri = request_uri(url, params)
        @requested_urls << uri.to_s
        cached = pending(uri.to_s) if resume
        return remember(cached) if cached

        response = @transport.get_response(uri.to_s, {}, headers: request_headers(uri, conditional))
        @last_checked_at = response.retrieved_at
        @not_modified = response.status == 304
        if @not_modified
          @validators[uri.to_s] = (@validators[uri.to_s] || {}).merge(validator_headers(response.headers))
          return nil
        end

        raise Error, "Source returned HTTP #{response.status}" unless response.status == 200

        retain_response(uri.to_s, response, binary: binary)
      end

      def validators = @validators.reject { |_, value| value.empty? }
      def not_modified? = @not_modified

      def fresh_get(url, params = {})
        get(url, params, conditional: false, resume: false)
      end

      def pending_body(url, params = {})
        pending(request_uri(url, params).to_s)&.fetch(:body)
      end

      def document_bytes(url)
        body = get(url, {}, binary: true)
        return body.b if body

        retained = retained_response(url)
        return retained[:body].b if retained

        get(url, {}, conditional: false, resume: false, binary: true).b
      end

      def retained_response(url)
        return unless @slug

        row = Storage.db[:water_responses].where(source_slug: @slug, url: url)
                     .order(Sequel.desc(:retrieved_at)).first
        row && { body: Zlib.gunzip(row[:body]), retrieved_at: row[:retrieved_at],
                 headers: JSON.parse(row[:headers] || '{}'), final_url: row[:final_url],
                 redirects: JSON.parse(row[:redirects] || '[]') }
      end

      def discard_pending!
        Muni::Store.with_writer { Storage.db[:water_pending_pages].where(source_slug: @slug).delete } if @slug
        @responses.clear
        @validators.clear
        @snapshot_time = Time.now.utc
        @last_retrieved_at = nil
        @not_modified = false
      end

      private

      def request_uri(url, params)
        uri = URI(url)
        query = URI.encode_www_form(params)
        uri.query = [uri.query, query].compact.reject(&:empty?).join('&') unless query.empty?
        uri
      end

      def request_headers(uri, conditional)
        headers = {}
        headers.merge!(@validators[uri.to_s] || {}) if conditional
        headers['X-Api-Key'] = ENV['USGS_API_KEY'] if uri.host == 'api.waterdata.usgs.gov' && ENV['USGS_API_KEY']
        headers
      end

      def retain_response(url, response, binary: false)
        body = response.body.to_s.dup.force_encoding(binary ? Encoding::BINARY : Encoding::UTF_8)
        raise Error, 'Source returned an empty response' if body.empty?
        raise Error, 'Source response is not valid UTF-8' unless binary || body.valid_encoding?

        @validators[url] = validator_headers(response.headers)
        entry = { url: url, headers: response.headers.to_h, body: body, retrieved_at: response.retrieved_at,
                  final_url: response.url || url, redirects: response.redirects || [] }
        stage(entry)
        remember(entry)
      end

      def prepare_pending
        pages = Storage.db[:water_pending_pages].where(source_slug: @slug)
        earliest = Water.time(pages.min(Sequel.function(:coalesce, :snapshot_at, :retrieved_at)))
        if pages.where(snapshot_at: nil, retrieved_at: nil).any? || (earliest && @snapshot_time - earliest > 86_400)
          Muni::Store.with_writer { pages.delete }
        elsif earliest
          @snapshot_time = earliest
        end
      end

      def pending(url)
        return unless @slug

        row = Storage.db[:water_pending_pages].where(source_slug: @slug, url: url).first
        row && { url: url, headers: JSON.parse(row[:headers]),
          body: Zlib.gunzip(row[:body]).force_encoding(Encoding::UTF_8),
                 retrieved_at: row[:retrieved_at], final_url: row[:final_url] || url,
                 redirects: JSON.parse(row[:redirects] || '[]') }
      end

      def stage(entry)
        return unless @slug

        row = entry.merge(source_slug: @slug, snapshot_at: @snapshot_time,
                          body: Sequel.blob(Zlib.gzip(entry[:body])), headers: Water.json(entry[:headers]),
                          redirects: Water.json(entry[:redirects]))
        Muni::Store.with_writer { Storage.db[:water_pending_pages].insert_conflict.insert(row) }
      end

      def remember(entry)
        @not_modified = false
        @responses << entry
        @last_retrieved_at = entry[:retrieved_at]
        @validators[entry[:url]] = validator_headers(entry[:headers])
        entry[:body]
      end

      def validator_headers(headers)
        { 'If-None-Match' => headers['etag'], 'If-Modified-Since' => headers['last-modified'] }.compact
      end
    end
  end
end
