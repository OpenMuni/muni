require 'muni/command'
require 'muni/helpers/normalize'

module Muni
  module CLI
    module Commands
      module Records
        class Ls < Muni::Command
          description 'List records of a given type.'
          argument :type, required: true
          option :hall,  default: nil
          option :since, default: nil
          option :limit, type: :integer, default: 25

          def go
            since = opts[:since] ? Time.now.utc - Muni::Helpers::Normalize.parse_duration(opts[:since]) : nil
            emit(Muni::Data.records_for_type(args[:type], hall: opts[:hall], since: since, limit: opts[:limit].to_i))
          rescue Muni::Data::NotFound => e
            fail!(e.message)
          end
        end

        class Show < Muni::Command
          description 'Show one record by primary key.'
          argument :type, required: true
          option :id, default: nil

          def go
            fail!('--id is required') if opts[:id].nil? || opts[:id].empty?

            emit(Muni::Data.record_for_type(args[:type], id: opts[:id]))
          rescue Muni::Data::NotFound => e
            fail!(e.message)
          end
        end
      end
    end
  end
end

Muni::CLI::Router.register('records', default: :ls,
                                      ls:      Muni::CLI::Commands::Records::Ls,
                                      show:    Muni::CLI::Commands::Records::Show)
