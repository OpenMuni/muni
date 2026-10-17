require 'faraday'
require 'faraday/retry'
require 'json'
require 'time'
require 'uri'

module Muni
  module Helpers
    # Thin Faraday wrapper used by every Source. Adds retry, JSON parsing, and
    # opt-in ETag/304 handling. We deliberately avoid faraday-http-cache so the
    # caller controls cache semantics per source.
    class Http
      class NotModified < StandardError; end
      Response = Struct.new(:status, :headers, :body, :url, :retrieved_at, :requested_url, :redirects,
                            keyword_init: true)
      RETRY_STATUSES = [429, 500, 502, 503, 504].freeze
      REDIRECT_STATUSES = [301, 302, 303, 307, 308].freeze
      CROSS_ORIGIN_HEADERS = %w[accept accept-encoding user-agent if-none-match if-modified-since cache-control
                                range].freeze

      class Error < StandardError
        attr_reader :status, :body, :retry_at

        def initialize(status, body, headers: {}, now: Time.now.utc)
          @status = status
          @body = body
          @retry_at = retry_time(headers['retry-after'], now)
          super(status ? "HTTP #{status}: #{body.to_s[0, 200]}" : "HTTP transport failed: #{body}")
        end

        def retryable? = status.nil? || RETRY_STATUSES.include?(status)

        private

        def retry_time(value, now)
          return if value.to_s.empty?
          return now + value.to_i if value.to_s.match?(/\A\d+\z/)

          Time.httpdate(value.to_s)
        rescue ArgumentError
          nil
        end
      end

      def initialize(base_url:, headers: {}, timeout: 20, open_timeout: 10, retries: 3,
                     follow_redirects: false, max_redirects: 3)
        @follow_redirects = follow_redirects
        @max_redirects = Integer(max_redirects)
        @conn = Faraday.new(url: base_url, request: { timeout: timeout, open_timeout: open_timeout }) do |f|
          f.headers.merge!(default_headers.merge(headers))
          f.request :retry, max: retries, interval: 1, interval_randomness: 0.25, backoff_factor: 2,
                            retry_statuses: RETRY_STATUSES,
                            methods: %i[get head options],
                            exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed,
                                         Faraday::ServerError, Faraday::RetriableResponse]
          f.adapter Faraday.default_adapter
        end
      end

      # Raw bytes and response provenance for callers that own parsing or journaling.
      def get_response(path, params = {}, headers: {})
        response = request_response(:get, path, params: params, headers: headers)
        @follow_redirects ? follow_get_redirects(response, headers) : response
      end

      def get(path, params = {}, headers: {}, etag: nil)
        do_request(:get, path, params: params, headers: headers, etag: etag)
      end

      # Like `get` but always returns the raw response body string. Used by
      # the HTML scraper client where Nokogiri needs the original bytes.
      def get_raw(path, params = {}, headers: {})
        req_headers = { 'Accept' => 'text/html,application/xml;q=0.9,*/*;q=0.8' }.merge(headers)
        get_response(path, params, headers: req_headers).body.to_s
      end

      def post(path, body = nil, headers: {})
        do_request(:post, path, body: body, headers: headers)
      end

      def put(path, body = nil, headers: {})
        do_request(:put, path, body: body, headers: headers)
      end

      private

      def default_headers
        { 'Accept'     => 'application/json',
          'User-Agent' => "muni.fyi/#{Muni::VERSION} (hello@muni.fyi)" }
      end

      def do_request(verb, path, params: nil, body: nil, headers: {}, etag: nil)
        req_headers = headers.dup
        req_headers['If-None-Match'] = etag if etag
        handle_response(request_response(verb, path, params: params, body: body, headers: req_headers))
      end

      def request_response(verb, path, params: nil, body: nil, headers: {}, cross_origin: false)
        req_headers = headers.dup
        log(verb, path, params)
        resp = @conn.run_request(verb, path, body && encode_body(body, req_headers), req_headers) do |req|
          req.params.update(params) if params
          req.headers.delete_if { |key, _| !CROSS_ORIGIN_HEADERS.include?(key.downcase) } if cross_origin
        end
        log_resolved_url(resp.env) if Muni::Logger.instance.debug?
        received = Time.now.utc
        raise Error.new(resp.status, resp.body, headers: resp.headers, now: received) if resp.status >= 400

        Response.new(status: resp.status, headers: resp.headers.to_h, body: resp.body.to_s,
                     url: resp.env.url.to_s, retrieved_at: received).freeze
      rescue Faraday::RetriableResponse => e
        r = e.response.is_a?(Hash) ? e.response : { status: e.response.status, body: e.response.body }
        raise Error.new(r[:status], r[:body], headers: r[:headers] || {})
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
        raise Error.new(nil, e.message)
      end

      def follow_get_redirects(response, headers)
        requested_url = response.url
        redirects = []
        cross_origin = false
        while REDIRECT_STATUSES.include?(response.status)
          target = redirect_target(response, redirects)
          redirects << { 'status' => response.status, 'from' => response.url, 'to' => target.to_s }
          cross_origin ||= origin(URI(response.url)) != origin(target)
          response = request_response(:get, target.to_s, headers: headers, cross_origin: cross_origin)
        end
        Response.new(**response.to_h, requested_url: requested_url, redirects: redirects).freeze
      end

      def redirect_target(response, redirects)
        if redirects.length >= @max_redirects || response.headers['location'].to_s.empty?
          raise Error.new(response.status, 'GET redirect limit reached or Location is missing')
        end

        target = URI.join(response.url, response.headers['location'])
        unless %w[http https].include?(target.scheme) && target.host
          raise Error.new(response.status, 'GET redirect must use an HTTP(S) URL')
        end

        target.userinfo = nil
        if target.to_s == response.url || redirects.any? { |hop| hop['from'] == target.to_s }
          raise Error.new(response.status, 'GET redirect loop detected')
        end

        target
      rescue URI::InvalidURIError => e
        raise Error.new(response.status, "Invalid GET redirect: #{e.message}")
      end

      def origin(uri) = [uri.scheme, uri.host, uri.port]

      def encode_body(body, headers)
        return body if body.is_a?(String)

        headers['Content-Type'] ||= 'application/json'
        JSON.dump(body)
      end

      def handle_response(resp)
        return :not_modified if resp.status == 304
        raise Error.new(resp.status, resp.body) if resp.status >= 400

        return resp.body if resp.body.to_s.empty?

        content = resp.headers['content-type'].to_s
        content.include?('json') ? JSON.parse(resp.body) : resp.body
      end

      def log(verb, path, params)
        Muni::Logger.instance.debug("HTTP #{verb.to_s.upcase} #{path} #{params&.inspect}")
      rescue StandardError
        nil
      end

      def log_resolved_url(env)
        Muni::Logger.instance.debug("HTTP URL #{env.url}")
      rescue StandardError
        nil
      end
    end
  end
end
