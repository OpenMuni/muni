require 'spec_helper'

RSpec.describe Muni::Store do
  it 'applies the same bounded SQLite settings to later connections' do
    described_class.ensure_tables!
    database = described_class.db
    connections = Queue.new
    release = Queue.new
    workers = 4.times.map do
      Thread.new do
        database.synchronize do |connection|
          connections << %w[cache_size temp_store synchronous busy_timeout].to_h do |setting|
            [setting, connection.get_first_value("PRAGMA #{setting}")]
          end
          release.pop
        end
      end
    end
    values = 4.times.map { connections.pop }
    expect(values.uniq).to eq([{ 'cache_size' => -2000, 'temp_store' => 1, 'synchronous' => 1,
                               'busy_timeout' => 5000 }])
  ensure
    4.times { release << true } if release
    workers&.each(&:join)
  end
end
