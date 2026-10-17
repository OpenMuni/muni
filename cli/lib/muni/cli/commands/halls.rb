require 'muni/command'

module Muni
  module CLI
    module Commands
      module Halls
        class List < Muni::Command
          description 'List configured city halls.'

          def go
            rows = Muni::Hall.all.map(&:to_h)
            emit(rows)
          end
        end

        class Show < Muni::Command
          description 'Show one hall in detail.'
          argument :slug, required: true

          def go
            hall = Muni::Hall.find(args[:slug]) or fail!("no hall: #{args[:slug]}")
            emit(hall.to_h)
          end
        end
      end
    end
  end
end

Muni::CLI::Router.register('halls', default: :list,
                                    list:    Muni::CLI::Commands::Halls::List,
                                    show:    Muni::CLI::Commands::Halls::Show)
