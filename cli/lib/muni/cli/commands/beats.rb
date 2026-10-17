require 'muni/command'

module Muni
  module CLI
    module Commands
      module Beats
        class List < Muni::Command
          description 'List every scheduled Beat.'

          def go
            rows = Muni::Registry.beats.values.map do |klass|
              last = Muni::Store.recent_beat_runs(limit: 100).find { |r| r[:beat_slug] == klass.slug }
              { slug: klass.slug, every: klass.every, mode: klass.mode,
                limit: klass.limit, cursor: klass.cursor,
                last_run: last && last[:started_at], last_error: last && last[:error] }
            end
            emit(rows.sort_by { |r| r[:slug] })
          end
        end

        class Run < Muni::Command
          description 'Run one Beat once and exit.'
          argument :slug, required: true

          def go
            Muni::Store.ensure_tables!
            klass = Muni::Registry.beat(args[:slug]) or fail!("unknown beat: #{args[:slug]}")
            result = klass.new.run!
            emit(slug: klass.slug, rows_in: result[:rows_in],
                 rows_upserted: result[:rows_upserted], error: result[:error]&.message)
          end
        end

        class Serve < Muni::Command
          description 'Boot the supervisor loop and run beats indefinitely.'

          def go
            Muni::Store.ensure_tables!
            Muni::Scheduler.new.run!
          end
        end

        class Tail < Muni::Command
          description 'Follow the beats_log table.'
          option :limit, type: :integer, default: 25

          def go
            rows = Muni::Store.recent_beat_runs(limit: opts[:limit].to_i)
            emit(rows.map { |r| r.transform_values { |v| v.is_a?(Time) ? v.iso8601 : v } })
          end
        end

        class Seed < Muni::Command
          description 'Run every beat once (local seed / Fly warmup).'
          option :hall, type: :string, default: nil
          option :waterbody, type: :string, default: nil

          def go
            Muni::Store.ensure_tables!
            fail!("unknown Hall: #{opts[:hall]}") if opts[:hall] && !Muni::Hall.find(opts[:hall])
            results = seed_results
            if json?
              emit(results: results, counts: Muni::Store.counts_by_source(hall: opts[:hall]))
            else
              print_table(results)
              puts
              counts = Muni::Store.counts_by_source(hall: opts[:hall])
              puts "Store totals: #{counts.values.sum} rows across sources"
            end
          end

          private

          def seed_results
            fail!('Use either --hall or --waterbody') if opts[:hall] && opts[:waterbody]
            return Muni::Beats.run_all_once!(hall: opts[:hall]) unless opts[:waterbody]

            unless Muni::Water.enabled? && opts[:waterbody] == 'charles'
              fail!('Water collection requires MUNI_WATER_ENABLED=1 and --waterbody=charles')
            end
            selected = Muni::Registry.beats.values.select { |beat| beat.slug.start_with?(Muni::Water::PREFIX) }
            Muni::Beats.run_all_once!(beats: selected)
          end

          def print_table(results)
            template = "%<beat>-40s %<rows_in>8s %<upserted>10s %<status>s\n"
            printf(template, beat: 'beat', rows_in: 'rows_in', upserted: 'upserted', status: 'status')
            printf(template, beat: '-' * 40, rows_in: '-' * 8, upserted: '-' * 10, status: '-' * 6)
            results.each do |r|
              status = r[:error] ? "ERR #{r[:error]}" : 'ok'
              printf(template, beat: r[:slug], rows_in: r[:rows_in], upserted: r[:rows_upserted], status: status)
            end
          end
        end
      end
    end
  end
end

Muni::CLI::Router.register('beats', default: :list,
                                    list:    Muni::CLI::Commands::Beats::List,
                                    run:     Muni::CLI::Commands::Beats::Run,
                                    serve:   Muni::CLI::Commands::Beats::Serve,
                                    tail:    Muni::CLI::Commands::Beats::Tail,
                                    seed:    Muni::CLI::Commands::Beats::Seed)
