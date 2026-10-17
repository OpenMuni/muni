require 'muni'

module Muni
  module CLI
    # Dispatches `muni <namespace> <action> [args]`. Each namespace maps to
    # a hash of action => Muni::Command subclass.
    class Router
      def self.namespaces
        @namespaces ||= {}
      end

      def self.register(namespace, actions)
        namespaces[namespace.to_s] = actions
      end

      def initialize(argv)
        @argv = argv.dup
      end

      def call
        Muni.boot!
        Muni::Hall.load_all!

        case @argv.first
        when '--version', '-v'
          puts Muni::VERSION
          0
        when nil, 'help', '--help', '-h'
          print_help
          0
        else
          dispatch(@argv.shift, @argv)
        end
      end

      private

      def dispatch(namespace, rest)
        actions = self.class.namespaces[namespace]
        return unknown("unknown namespace: #{namespace}") unless actions

        default = actions[:default]
        next_token = rest.first

        cmd = if next_token.nil? || next_token.start_with?('-')
                actions[default]
              elsif actions[next_token.to_sym]
                actions[rest.shift.to_sym]
              else
                actions[default]
              end

        return unknown("unknown command: #{namespace} #{next_token}") unless cmd

        cmd.new(rest).call
      end

      def unknown(msg)
        warn msg
        warn 'run `muni help` for usage'
        1
      end

      def print_help
        puts <<~HELP
          muni v#{Muni::VERSION}

          Usage: muni [--version] <namespace> <command> [options]

          Namespaces:
            halls      list / show city configurations
            sources    list registered sources / dry-run a fetch
            beats      run, serve, or tail scheduled jobs
            analytics  run or show cached civic analytics
            get        fetch normalized Cambridge data (311, police, permits, crashes, trees, food_trucks)
            meetings   backfill / summarize / list Granicus meeting records
            records    query the local store
            data       migrate the SQLite schema
            serve      boot the Sinatra web app

          Collector binaries: muni-get-311, muni-get-police, muni-get-permits,
            muni-get-crashes, muni-get-trees, muni-get-food-trucks.
          Zone: positional `cambridge,ma` or --zone/--city=cambridge,ma or MUNI_ZONE.

          Global options:
            --json     emit machine-readable output
            -y/--yes   auto-accept every question
            -h/--help  print command help
        HELP
      end
    end
  end
end
