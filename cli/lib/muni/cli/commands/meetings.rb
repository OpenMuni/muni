require 'time'
require 'muni/command'
require 'muni/helpers/normalize'

module Muni
  module CLI
    module Commands
      # Operator controls for the Meetings vertical: scrape the Granicus archive
      # (backfill any window) and generate Claude summaries in bounded batches.
      module Meetings
        # Shared --since parsing: accepts a date (2021-01-01) or a duration (2y, 30d).
        module SinceOption
          def parse_since(value)
            raw = value.to_s.strip
            return nil if raw.empty?
            return Time.parse(raw).utc if raw.match?(/\A\d{4}-\d{2}-\d{2}/)

            Time.now.utc - Muni::Helpers::Normalize.parse_duration(raw)
          rescue ArgumentError
            fail!("invalid --since: #{value}")
          end
        end

        class Ls < Muni::Command
          description 'List stored meetings (newest first).'
          option :hall,  default: 'cambridge'
          option :limit, type: :integer, default: 25

          def go
            rows = Muni::Data.records_for_type('meetings', hall: opts[:hall], limit: opts[:limit].to_i)
            emit(rows.map do |r|
              { date: r[:meeting_at], body: r[:body], title: r[:title], summarized: !r[:ai_summary].nil? }
            end)
          rescue Muni::Data::NotFound => e
            fail!(e.message)
          end
        end

        class Backfill < Muni::Command
          include SinceOption

          description 'Scrape the Granicus archive into the store. Use --since to reach older years.'
          option :hall,   default: 'cambridge'
          option :since,  default: nil
          option :bodies, default: nil # comma-separated, e.g. "City Council,Planning Board"
          option :limit,  type: :integer, default: 200

          def go
            Muni::Store.ensure_tables!
            since = parse_since(opts[:since])
            bodies = opts[:bodies].to_s.split(',').map(&:strip).reject(&:empty?)
            source = Cambridge::Meetings.new(bodies: bodies)
            now = Time.now.utc
            records = source.pull(since: since, limit: opts[:limit].to_i)
            records.each do |record|
              record.collected_at = now
              record.last_seen_at = now
              Muni::Store.upsert(record)
            end
            Muni::Store.bump_seen(source.class.slug, now) unless records.empty?
            emit(backfilled: records.size, since: since&.iso8601, bodies: bodies.empty? ? 'default (3 bodies)' : bodies)
          end
        end

        class Summarize < Muni::Command
          include SinceOption

          description 'Generate Claude summaries for meetings missing one (bounded batch).'
          option :hall,  default: 'cambridge'
          option :limit, type: :integer, default: 10
          option :since, default: nil
          option :body,  default: nil
          option :force, boolean: true, default: false

          def go
            Muni::Store.ensure_tables!
            client = Muni::AnthropicClient.new
            fail!('ANTHROPIC_API_KEY is not configured') unless client.configured?

            tally = Muni::Meetings::Summarizer.summarize_pending(
              hall:   opts[:hall],
              limit:  opts[:limit].to_i,
              since:  parse_since(opts[:since]),
              body:   opts[:body],
              force:  opts[:force] == true,
              client: client
            )
            emit(tally)
          end
        end
      end
    end
  end
end

Muni::CLI::Router.register(
  'meetings',
  default:   :list,
  list:      Muni::CLI::Commands::Meetings::Ls,
  backfill:  Muni::CLI::Commands::Meetings::Backfill,
  summarize: Muni::CLI::Commands::Meetings::Summarize
)
