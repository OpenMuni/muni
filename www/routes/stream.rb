require 'sinatra/base'
require 'json'
require 'muni'

module Muni
  module Www
    module Routes
      class Stream < Sinatra::Base
        set :host_authorization, { permitted_hosts: [] }

        get '/stream/category/:slug' do
          hall = params[:hall]
          cat = Muni::View.find(params[:slug]) or halt 404, 'unknown category'
          source_slugs = Muni::View.sources_for(cat.slug, hall)
          stream_category(source_slugs, hall)
        end

        get '/stream/:scope/:name' do
          source_slug = "#{params[:scope]}/#{params[:name]}"
          Muni::Registry.source(source_slug) or halt 404, 'unknown source'
          hall = params[:hall]
          stream_category([source_slug], hall)
        end

        private

        def stream_category(source_slugs, hall)
          content_type 'text/event-stream'
          cache_control :no_cache
          headers 'X-Accel-Buffering' => 'no'

          # EventSource reconnects after this finite response. Never park a Puma
          # worker waiting for new records or for an idle client to disconnect.
          now = Time.now.utc
          rows = stream_rows(source_slugs, hall, stream_cursor(now))
          frames = rows.reverse.map { |row| "data: #{JSON.dump(row.to_h)}\n\n" }
          "retry: 15000\n\n#{frames.join}id: #{now.iso8601(6)}\n\n"
        end

        def stream_cursor(now)
          value = request.env['HTTP_LAST_EVENT_ID'].to_s
          cursor = value.empty? ? now - 30 : Time.iso8601(value)
          # Bound reconnect queries, including client-supplied stale/future IDs.
          cursor.clamp(now - 60, now)
        rescue ArgumentError
          now - 30
        end

        def stream_rows(source_slugs, hall, cursor)
          rows = source_slugs.flat_map do |source_slug|
            source = Muni::Registry.source(source_slug) or next []
            query = Muni::Store.source_where(source_slug, source, hall: hall || source.hall)
            query[:since] = cursor
            query[:limit] = 50
            Muni::Store.query(source.emits, **query)
          end
          Muni::View.merge_rows(rows, 50)
        end
      end
    end
  end
end
