require 'sinatra/base'
require 'muni'

module Muni
  module Www
    module Routes
      # Serves Protomaps PMTiles from the mounted volume. Fly's proxy forwards
      # /tiles/* here over 6PN; PMTiles clients require HTTP Range support.
      class Tiles < Sinatra::Base
        set :host_authorization, { permitted_hosts: [] }

        get '/tiles/*' do
          rel = params[:splat].first.to_s
          halt 404, 'not found' if rel.empty? || rel.include?('..')

          path = File.join(tiles_dir, rel)
          halt 404, 'not found' unless File.file?(path)

          headers 'Accept-Ranges' => 'bytes',
                  'Cache-Control' => 'public, max-age=86400, immutable',
                  'Content-Type'  => content_type_for(path)

          range = request.env['HTTP_RANGE']
          if range && range =~ /\Abytes=(\d+)-(\d*)\z/
            send_file_range(path, Regexp.last_match(1).to_i, Regexp.last_match(2))
          else
            send_file path
          end
        end

        private

        def tiles_dir
          ENV.fetch('MUNI_TILES_PATH', File.join(Muni::Config.data_dir, 'tiles'))
        end

        def content_type_for(path)
          path.end_with?('.pmtiles') ? 'application/vnd.pmtiles' : 'application/octet-stream'
        end

        def send_file_range(path, start_byte, end_byte)
          size = File.size(path)
          finish = end_byte.empty? ? size - 1 : [end_byte.to_i, size - 1].min
          halt 416 if start_byte >= size || finish < start_byte

          length = finish - start_byte + 1
          headers 'Content-Range'  => "bytes #{start_byte}-#{finish}/#{size}",
                  'Content-Length' => length.to_s
          status 206
          stream do |out|
            File.open(path, 'rb') do |io|
              io.seek(start_byte)
              remaining = length
              while remaining.positive?
                chunk = io.read([remaining, 65_536].min)
                break unless chunk

                out << chunk
                remaining -= chunk.bytesize
              end
            end
          end
        end
      end
    end
  end
end
