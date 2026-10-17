require 'spec_helper'

RSpec.describe Muni::Store::OnlineBackup do
  before { Muni::Store.ensure_tables! }

  def verify_backup(path)
    copy = Sequel.sqlite(path, readonly: true)
    expect(copy[:meta].where(key: 'collected_during_backup').get(:value)).to eq('complete')
    expect(copy.fetch('PRAGMA integrity_check').all).to eq([{ integrity_check: 'ok' }])
    expect(copy.fetch('PRAGMA journal_mode').first[:journal_mode]).to eq('delete')
  ensure
    copy&.disconnect
  end

  it 'yields without the writer lock and includes intervening writes in a self-contained backup' do
    store = Muni::Store
    store.set_meta('large_backup_fixture', 'x' * 2_000_000)
    yielded = 0
    Thread.current[:muni_scheduler_yield] = lambda do
      yielded += 1
      store.set_meta('collected_during_backup', 'complete')
    end
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'backup.sqlite3')
      store.online_backup(path)
      expect(yielded).to be_positive
      verify_backup(path)
      expect(Dir.children(directory)).to eq(['backup.sqlite3'])
    end
  ensure
    Thread.current[:muni_scheduler_yield] = nil
  end
end
