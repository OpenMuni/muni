require 'muni/helpers/http'

module Muni
  module Clients
    # Socrata SoDA 2.1 client. Public reads work without a key but are
    # rate-limited; pass an `app_token` (or set ENV['SOCRATA_APP_TOKEN']).
    #
    #   socrata = Muni::Clients::Socrata.new(base_url: 'https://data.cambridgema.gov')
    #   socrata.query(resource: 'k27e-shha', where: "issue_date > '2026-01-01'", limit: 500)
    class Socrata
      PAGE_SIZE = 1_000

      def initialize(base_url:, app_token: ENV.fetch('SOCRATA_APP_TOKEN', nil))
        headers = app_token ? { 'X-App-Token' => app_token } : {}
        @http = Muni::Helpers::Http.new(base_url: base_url, headers: headers)
      end

      # `resource` is the four-by-four (e.g. 'k27e-shha'); we resolve to the
      # JSON endpoint automatically. `limit` caps the total rows returned.
      def query(resource:, where: nil, order: nil, limit: nil, select: nil, group: nil, offset: 0)
        rows = []
        next_offset = offset.to_i
        page = [PAGE_SIZE, limit].compact.min
        endpoint = "/resource/#{resource}.json"

        loop do
          params = { '$limit' => page, '$offset' => next_offset }
          params['$where']  = where  if where
          params['$order']  = order  if order
          params['$select'] = select if select
          params['$group']  = group  if group
          batch = @http.get(endpoint, params)
          rows.concat(Array(batch))
          break if batch.size < page
          break if limit && rows.size >= limit

          next_offset += page
        end

        limit ? rows.first(limit) : rows
      end
    end
  end
end
