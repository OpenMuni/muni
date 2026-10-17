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

          stream(:keep_open) do |out|
            stream_loop(out, source_slugs, hall)
          rescue IOError
            out.close
          end
        end

        def stream_loop(out, source_slugs, hall)
          cursor = Time.now.utc
          beats_cursor = Muni::Store.last_beats_log_id
          idle_polls = 0
          floor = ENV.fetch('MUNI_SSE_INTERVAL', '2').to_f

          loop do
            current_beats = Muni::Store.last_beats_log_id
            beats_changed = current_beats > beats_cursor
            beats_cursor = current_beats if beats_changed

            rows = stream_rows(source_slugs, hall, cursor)
            cursor = Time.now.utc if rows.any?
            idle_polls = rows.any? ? 0 : idle_polls + 1
            rows.reverse_each { |r| out << "data: #{JSON.dump(r.to_h)}\n\n" }

            sleep(stream_sleep(floor, idle_polls, beats_changed))
          end
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

        def stream_sleep(floor, idle_polls, beats_changed)
          return floor if beats_changed || idle_polls.zero?

          [floor * (2**idle_polls), 30].min
        end
      end
    end
  end
end
