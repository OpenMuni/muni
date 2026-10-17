require 'muni/command'
require 'muni/helpers/normalize'

module Muni
  module CLI
    module Commands
      module Sources
        class List < Muni::Command
          description 'List every registered Source.'

          def go
            rows = Muni::Registry.sources.values.map do |klass|
              { slug: klass.slug, hall: klass.hall, emits: klass.emits.name, base_url: klass.base_url }
            end
            emit(rows.sort_by { |r| r[:slug] })
          end
        end

        # Dry-run a source pull and emit records without writing to the store.
        class Fetch < Muni::Command
          description 'Invoke a Source#pull and emit results (no store writes).'
          argument :slug, required: true
          option :since,  default: nil
          option :limit,  type: :integer, default: 100

          def go
            klass = Muni::Registry.source(args[:slug]) or fail!("unknown source: #{args[:slug]}")
            since = opts[:since] ? Time.now.utc - Muni::Helpers::Normalize.parse_duration(opts[:since]) : nil
            records = Array(klass.new.pull(since: since, limit: opts[:limit].to_i))
            emit(records.map(&:to_h))
          end
        end
      end
    end
  end
end

Muni::CLI::Router.register('sources', default: :list,
                                      list:    Muni::CLI::Commands::Sources::List,
                                      fetch:   Muni::CLI::Commands::Sources::Fetch)
