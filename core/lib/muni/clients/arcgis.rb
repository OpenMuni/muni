require 'muni/helpers/http'

module Muni
  module Clients
    # Minimal ArcGIS REST client for read-only FeatureServer/MapServer queries.
    class Arcgis
      DEFAULT_PAGE_SIZE = 1_000

      def initialize(base_url:, transport: nil)
        @http = transport || Muni::Helpers::Http.new(base_url: base_url)
      end

      # The caller owns journaling; this client owns the ArcGIS page contract.
      def each_page(path:, params:, page_size: DEFAULT_PAGE_SIZE, offset: 0, limit: nil, fetch: nil)
        unless block_given?
          return enum_for(__method__, path: path, params: params, page_size: page_size,
                                     offset: offset, limit: limit, fetch: fetch)
        end

        fetch ||= ->(target, query) { @http.get(target, query) }
        count = 0
        page_size = [page_size.to_i, 1].max
        loop do
          break if limit && count >= limit

          size = limit ? [page_size, limit - count].min : page_size
          payload = feature_page(fetch.call(path, params.merge('resultOffset' => offset, 'resultRecordCount' => size)))
          batch = payload['features']
          more = payload['exceededTransferLimit'] || batch.length == size
          raise Muni::Helpers::Http::Error.new(200, 'ArcGIS pagination did not advance') if more && batch.empty?

          yield batch
          count += batch.length
          break unless more

          offset += batch.length
          raise Muni::Helpers::Http::Error.new(200, 'ArcGIS page limit exceeded') if offset > 1_000_000
        end
      end

      def query_geojson(path:, where: '1=1', out_fields: '*', out_sr: 4326, limit: nil, offset: 0,
                        page_size: DEFAULT_PAGE_SIZE)
        features = []
        params = query_params(where, out_fields, out_sr)
        each_page(path: path, params: params, offset: offset.to_i, page_size: page_size,
                  limit: limit&.to_i) { |batch| features.concat(batch) }
        features
      end

      private

      def feature_page(payload)
        payload = JSON.parse(payload) if payload.is_a?(String)
        unless payload.is_a?(Hash) && !payload['error'] && payload['features'].is_a?(Array)
          raise Muni::Helpers::Http::Error.new(200, 'Invalid ArcGIS feature page')
        end

        payload
      rescue JSON::ParserError
        raise Muni::Helpers::Http::Error.new(200, 'Invalid ArcGIS JSON')
      end

      def query_params(where, out_fields, out_sr)
        {
          'f'         => 'geojson',
          'where'     => where,
          'outFields' => Array(out_fields).join(','),
          'outSR'     => out_sr
        }
      end
    end
  end
end
