require 'muni/command'
require 'muni/zone'
require 'muni/get/registry'
require 'muni/get/runner'
require 'muni/helpers/normalize'

module Muni
  module CLI
    module Get
      # Shared command surface for the launch collector binaries and `muni get`.
      class Command < Muni::Command
        description 'Fetch normalized municipal data for a domain.'

        argument :place, required: false

        option :provider, default: nil
        option :zone,     default: nil
        option :city,     default: nil
        option :since,    default: nil
        option :limit,    type: :integer, default: 25
        option :cached,   boolean: true, default: false
        option :persist,  boolean: true, default: false

        def initialize(domain, argv = [], **io)
          @domain_slug = domain
          super(argv, **io)
        end

        def go
          Muni.boot!
          Muni::Hall.load_all!

          domain = Muni::Get::Registry.find!(@domain_slug)
          zone = resolve_zone
          since = build_since

          result = Muni::Get::Runner.new(
            domain:   domain,
            zone:     zone,
            provider: opts[:provider],
            since:    since,
            limit:    opts[:limit].to_i,
            live:     !opts[:cached],
            persist:  opts[:persist]
          ).call

          emit(result.to_h)
        rescue ArgumentError => e
          fail!(e.message)
        end

        private

        def resolve_zone
          raw = [opts[:zone], opts[:city], args[:place], ENV.fetch('MUNI_ZONE', nil)].find do |v|
            v && !v.to_s.strip.empty?
          end
          return nil if raw.nil?

          Muni::Zone.parse!(raw)
        rescue Muni::Zone::Unknown => e
          fail!(e.message)
        end

        def build_since
          return nil unless opts[:since]

          Time.now.utc - Muni::Helpers::Normalize.parse_duration(opts[:since])
        end
      end

      class List < Muni::Command
        description 'List available muni-get domains and providers.'

        def go
          rows = Muni::Get::Registry.all.map do |d|
            {
              domain:    d.slug,
              title:     d.title,
              providers: d.provider_keys,
              zone:      d.requires_zone ? 'required' : 'optional'
            }
          end
          emit(rows)
        end
      end

      module Launcher
        module_function

        def run!(domain, argv = ARGV)
          require 'muni/cli/get'
          exit Muni::CLI::Get::Command.new(domain, argv).call
        end
      end
    end
  end
end
