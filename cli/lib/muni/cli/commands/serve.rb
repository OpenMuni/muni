require 'muni/command'

module Muni
  module CLI
    module Commands
      module Serve
        class Run < Muni::Command
          description 'Boot the Sinatra web app on the given port.'
          option :port, type: :integer, default: 4567
          option :bind, default: '127.0.0.1'

          def go
            Muni::Store.ensure_tables!
            require_app!
            handler = load_handler
            emit(ok: true, bind: opts[:bind], port: opts[:port].to_i)
            handler.run(Muni::Www::App, Port: opts[:port].to_i, Host: opts[:bind],
                                      Threads: ENV.fetch('MUNI_WEB_THREADS', '0:5'))
          end

          private

          def require_app!
            $LOAD_PATH.unshift File.expand_path('../../../../../www', __dir__)
            require 'app'
          rescue LoadError => e
            fail!("could not load Sinatra app: #{e.message}")
          end

          def load_handler
            require 'rackup/handler'
            Rackup::Handler.get(:puma)
          end
        end
      end
    end
  end
end

Muni::CLI::Router.register('serve', default: :run,
                                    run:     Muni::CLI::Commands::Serve::Run)
