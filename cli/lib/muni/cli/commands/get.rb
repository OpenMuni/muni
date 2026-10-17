require 'muni'
require 'muni/cli/get'

module Muni
  module CLI
    module Commands
      module Get
        # `muni get` with no domain → list; `muni get 311` → domain command.
        class Dispatch < Muni::Command
          description 'Fetch normalized data: muni get <domain> [zone] [options]'
          option :provider, default: nil
          option :zone,     default: nil
          option :city,     default: nil
          option :since,    default: nil
          option :limit,    type: :integer, default: 25
          option :cached,   boolean: true, default: false
          option :persist,  boolean: true, default: false

          def go
            domain_token, rest = peel_domain(argv)
            if domain_token.nil?
              return Muni::CLI::Get::List.new(rest, stdout: stdout, stderr: stderr, stdin: stdin).call
            end

            domain = Muni::Get::Registry.find(domain_token)
            fail!("unknown domain: #{domain_token} (run `muni get list`)") unless domain

            Muni::CLI::Get::Command.new(domain.slug, rest, stdout: stdout, stderr: stderr, stdin: stdin).call
          end

          private

          def peel_domain(tokens)
            rest = tokens.dup
            leading = []
            domain = nil
            until rest.empty?
              tok = rest.first
              if tok.start_with?('-')
                leading << rest.shift
                leading << rest.shift if option_takes_value?(tok) && rest.first && !rest.first.start_with?('-')
              else
                domain = rest.shift
                break
              end
            end
            [domain, leading + rest]
          end

          def option_takes_value?(token)
            name = option_name(token)
            cfg = name && self.class.options[name]
            cfg && !cfg[:boolean] && !token.include?('=')
          end

          def option_name(token)
            if token.start_with?('--')
              token[2..].split('=', 2).first.to_sym
            else
              find_option_by_short(token[1..])
            end
          rescue Muni::Command::UnknownOption
            nil
          end
        end
      end
    end
  end
end

Muni::CLI::Router.register('get', default:  :dispatch,
                                  dispatch: Muni::CLI::Commands::Get::Dispatch,
                                  list:     Muni::CLI::Get::List)
