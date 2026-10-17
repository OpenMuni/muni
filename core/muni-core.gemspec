$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'muni/version'

Gem::Specification.new do |s|
  s.name        = 'muni-core'
  s.version     = Muni::VERSION
  s.summary     = 'Muni framework — Sources, Beats, Records, Halls, Plats.'
  s.description = 'The shared framework powering the muni.fyi CLI, web app, and MCP servers.'
  s.authors     = ['Muni Contributors']
  s.email       = ['hello@muni.fyi']
  s.homepage    = 'https://muni.fyi'
  s.license     = 'MIT'

  s.required_ruby_version = '>= 3.3'

  s.files = Dir['lib/**/*.rb'] + Dir['lib/muni/water/*.json'] + Dir['halls/*.yml']
  s.require_paths = ['lib']

  s.add_dependency 'faraday',       '~> 2.10'
  s.add_dependency 'faraday-retry', '~> 2.2'
  s.add_dependency 'nokogiri',      '~> 1.19'
  s.add_dependency 'pdf-reader',    '~> 2.12'
  s.add_dependency 'rss',           '~> 0.3'
  s.add_dependency 'sequel',        '~> 5.86'
  s.add_dependency 'sqlite3',       '~> 2.1'
end
