$LOAD_PATH.unshift File.expand_path('../core/lib', __dir__)
require 'muni/version'

Gem::Specification.new do |s|
  s.name        = 'muni-cli'
  s.version     = Muni::VERSION
  s.summary     = 'The muni CLI binstub and commands.'
  s.description = 'Ships the `muni` executable; thin router over Muni::Core commands.'
  s.authors     = ['Muni Contributors']
  s.email       = ['hello@muni.fyi']
  s.homepage    = 'https://muni.fyi'
  s.license     = 'MIT'

  s.required_ruby_version = '>= 3.3'

  s.files       = Dir['lib/**/*.rb'] + Dir['exe/*']
  s.bindir      = 'exe'
  s.executables = ['muni'] + Dir['exe/muni-get-*'].map { |f| File.basename(f) }
  s.require_paths = ['lib']

  s.add_dependency 'muni-core', Muni::VERSION
end
