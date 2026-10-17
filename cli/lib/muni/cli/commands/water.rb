require 'muni/command'

module Muni
  module CLI
    module Commands
      module Water
        class Advisory < Muni::Command
          description 'Import a reviewed official advisory from a local JSON file.'
          argument :file, required: true

          def go
            fail!('Set MUNI_WATER_ENABLED=1 to import water advisories') unless Muni::Water.enabled?
            Muni::Store.ensure_tables!
            attributes = JSON.parse(File.read(args[:file]))
            record = Muni::Water::Ingestor.new('official_advisories').import_advisory(attributes)
            emit(record)
          rescue JSON::ParserError, Muni::Water::Error, ArgumentError => e
            fail!(e.message)
          end
        end

        class Status < Muni::Command
          description 'Show shared water source coverage and collection health.'

          def go
            Muni::Store.ensure_tables!
            emit(Muni::Water::Query.new.envelope(methodology: Muni::Water::Query.new.methodology))
          end
        end

        class Metrics < Muni::Command
          description 'Show the same local readings and qualifications as the Charles River overview.'

          def go
            Muni::Store.ensure_tables!
            emit(Muni::Water::Query.new.metrics)
          end
        end

        class Reconcile < Muni::Command
          description 'Reconcile one publisher, or re-normalize retained evidence without checking the publisher.'
          argument :source, required: false
          option :normalize, type: :boolean, default: false

          def go
            Muni::Store.ensure_tables!
            return emit(Muni::Water::Reconciler.new.normalize(source: args[:source])) if opts[:normalize]

            id = args[:source].to_s.delete_prefix(Muni::Water::PREFIX)
            fail!('Choose a configured water source') unless Muni::Water::Catalog.definitions.key?(id)
            result = Muni::Water::Ingestor.new(id).run(reconcile: true)
            emit(result.merge(error: result[:error]&.message))
            fail!(result[:error].message) if result[:error]
          end
        end

        class Review < Muni::Command
          description 'Inspect unresolved evidence and its retained source revisions.'
          argument :id, required: false
          option :limit, type: :integer, default: 100

          def go
            Muni::Store.ensure_tables!
            query = Muni::Water::Query.new
            return emit(query.evidence(args[:id])) if args[:id]

            rows = Muni::Water::Storage.evidence.where(status: 'needs_review').order(:source_slug, :external_id)
            emit(records: rows.limit(opts[:limit].clamp(1, 500)).all.map do |row|
              Muni::Water::Eligibility.project(Muni::Water::Storage.decode(row)).except('raw')
            end, total: rows.count)
          end
        end
      end
    end
  end
end

Muni::CLI::Router.register('water', default: :status, status: Muni::CLI::Commands::Water::Status,
                                                    metrics: Muni::CLI::Commands::Water::Metrics,
                                                    reconcile: Muni::CLI::Commands::Water::Reconcile,
                                                    review: Muni::CLI::Commands::Water::Review,
                                                    advisory: Muni::CLI::Commands::Water::Advisory)
