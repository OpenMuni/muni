$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'tmpdir'

# Each spec gets a fresh on-disk SQLite so tests are isolated.
ENV['MUNI_DB_PATH'] ||= File.join(Dir.mktmpdir('muni-spec'), 'muni.sqlite3')

require 'muni'

RSpec.configure do |c|
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
