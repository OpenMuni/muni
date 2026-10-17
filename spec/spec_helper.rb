$LOAD_PATH.unshift File.expand_path('../core/lib', __dir__)
$LOAD_PATH.unshift File.expand_path('../cli/lib',  __dir__)
$LOAD_PATH.unshift File.expand_path('../www',      __dir__)

require 'tmpdir'
require 'fileutils'
require 'vcr'
require 'webmock/rspec'

ENV['RACK_ENV'] ||= 'test'
# Cambridge's floating timestamps are interpreted in local Eastern time.
ENV['TZ'] = 'America/New_York'

require 'muni'
require 'muni/cli'
require 'rack/test'
require 'app'

Muni.boot!

VCR.configure do |c|
  c.cassette_library_dir = File.expand_path('cassettes', __dir__)
  c.hook_into :webmock
  c.default_cassette_options = { record: :new_episodes, match_requests_on: %i[method uri] }
  c.allow_http_connections_when_no_cassette = false
end

RSpec.configure do |c|
  c.include Rack::Test::Methods
  c.expect_with(:rspec) { |e| e.syntax = :expect }
  c.disable_monkey_patching!

  c.around do |ex|
    saved_db = Muni::Store.instance_variable_get(:@db)
    Muni::Store.instance_variable_set(:@db, nil)
    tmp = Dir.mktmpdir('muni-spec-db')
    ENV['MUNI_DB_PATH'] = File.join(tmp, 'muni.sqlite3')
    ex.run
  ensure
    Muni::Store.reset!
    Muni::Store.instance_variable_set(:@db, saved_db)
    FileUtils.rm_rf(tmp) if tmp
  end
end
