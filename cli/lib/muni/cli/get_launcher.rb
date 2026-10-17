# Loaded by the launch collector executables in cli/exe/.
$LOAD_PATH.unshift(File.expand_path('../..', __dir__))
require 'muni'
require 'muni/cli/get'

module Muni
  module CLI
    module Get
      module Launcher
        module_function

        def run!(domain)
          exit Muni::CLI::Get::Command.new(domain, ARGV).call
        end
      end
    end
  end
end
