source 'https://rubygems.org'

ruby '3.3.6'

# The three sub-gems that make up the Muni monorepo. Each one is path-included
# so a single `bundle install` at the repo root resolves the whole project.
gemspec path: 'core', name: 'muni-core'
gemspec path: 'cli',  name: 'muni-cli'
gemspec path: 'www',  name: 'muni-www'

group :development, :test do
  gem 'rake',          '~> 13.2'
  gem 'rspec',         '~> 3.13'
  gem 'rubocop',       '~> 1.69'
  gem 'rubocop-rspec', '~> 3.3'
  gem 'vcr',           '~> 6.3'
  gem 'webmock',       '~> 3.34'
  gem 'rack-test',     '~> 2.1'
end
