require 'muni/command'

module Muni
  module CLI
    module Commands
      module Analytics
        class Run < Muni::Command
          description 'Compute cached analytics for a hall.'
          option :hall, default: 'cambridge'

          def go
            Muni::Store.ensure_tables!
            emit(Muni::Analytics.compute!(hall: opts[:hall]))
          end
        end

        class Show < Muni::Command
          description 'Show cached analytics for a hall.'
          option :hall, default: 'cambridge'

          def go
            Muni::Store.ensure_tables!
            emit(Muni::Analytics.snapshot(hall: opts[:hall]))
          end
        end

        class DigestContext < Muni::Command
          description 'Show source facts used to generate the Digest.'
          option :hall, default: 'cambridge'

          def go
            Muni::Store.ensure_tables!
            emit(Muni::Analytics.digest_context(hall: opts[:hall]))
          end
        end
      end
    end
  end
end

Muni::CLI::Router.register('analytics', default:          :show,
                                        run:              Muni::CLI::Commands::Analytics::Run,
                                        show:             Muni::CLI::Commands::Analytics::Show,
                                        'digest-context': Muni::CLI::Commands::Analytics::DigestContext)
