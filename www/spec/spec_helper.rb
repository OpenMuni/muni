$LOAD_PATH.unshift File.expand_path('../../core/lib', __dir__)
$LOAD_PATH.unshift File.expand_path('..', __dir__)

ENV['RACK_ENV'] ||= 'test'

require 'rack/test'
require 'app'

RSpec.configure do |c|
  c.include Rack::Test::Methods
  c.expect_with(:rspec) { |e| e.syntax = :expect }
  c.disable_monkey_patching!
end
