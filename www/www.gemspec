$LOAD_PATH.unshift File.expand_path('../core/lib', __dir__)
require 'muni/version'

Gem::Specification.new do |s|
  s.name        = 'muni-www'
  s.version     = Muni::VERSION
  s.summary     = 'Sinatra web frontend for muni.fyi.'
  s.description = 'Reads Muni::Store directly to render the calm city OS.'
  s.authors     = ['Muni Contributors']
  s.email       = ['hello@muni.fyi']
  s.homepage    = 'https://muni.fyi'
  s.license     = 'MIT'

  s.required_ruby_version = '>= 3.3'

  s.files         = Dir['app.rb', 'config.ru', 'auth/**/*.rb', 'routes/**/*.rb', 'views/**/*.erb', 'public/**/*']
  s.require_paths = ['.']

  s.add_dependency 'aws-sdk-cognitoidentityprovider', '~> 1'
  s.add_dependency 'jwt', '~> 3.1'
  s.add_dependency 'muni-core', Muni::VERSION
  s.add_dependency 'oauth2', '~> 2.0'
  s.add_dependency 'puma',      '~> 7.2', '>= 7.2.1'
  s.add_dependency 'rackup',    '~> 2.3'
  s.add_dependency 'sinatra',   '~> 4.1'
end
