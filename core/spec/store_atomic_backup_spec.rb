require 'spec_helper'

RSpec.describe Muni::Store, '.backup!' do
  let(:store) { described_class }
  let(:now) { Time.utc(2026, 10, 17, 12) }
  let(:backups) { ENV.fetch('MUNI_BACKUP_PATH') }
  let(:daily) { File.join(backups, 'daily-2026-10-17.sqlite3') }

  around do |example|
    previous = ENV.fetch('MUNI_BACKUP_PATH', nil)
    Dir.mktmpdir('atomic-backups') do |directory|
      ENV['MUNI_BACKUP_PATH'] = directory
      example.run
    end
  ensure
    previous ? ENV['MUNI_BACKUP_PATH'] = previous : ENV.delete('MUNI_BACKUP_PATH')
  end

  before do
    store.ensure_tables!
    allow(store).to receive(:maintenance_enabled?).and_return(true)
  end

  it 'keeps an invalid target on failed capture, removes only its temporary file, then recovers on retry' do
    File.write(daily, 'interrupted old backup')
    unrelated = File.join(backups, '.unrelated-file')
    File.write(unrelated, 'keep')
    failure = IOError.new('capture interrupted')
    allow(store).to receive(:online_backup) do |path|
      File.write(path, 'partial output')
      raise failure
    end

    expect { store.backup!(now: now) }.to(raise_error { |error| expect(error).to equal(failure) })
    expect(File.read(daily)).to eq('interrupted old backup')
    expect(File.read(unrelated)).to eq('keep')
    expect(Dir.glob(File.join(backups, '.muni-backup-*'))).to be_empty
    expect(store.meta('maintenance:last_backup')).to be_nil

    allow(store).to receive(:online_backup).and_call_original
    expect(store.backup!(now: now)).to eq(daily)
    expect(store.valid_backup?(daily)).to be(true)
    expect(Muni::Status::Backup.snapshot[:failure_state]).to eq('recovered')
  end

  it 'does not accept an empty target as a successful backup' do
    File.write(daily, '')
    store.backup!(now: now)

    expect(store.valid_backup?(daily)).to be(true)
    expect(File.size(daily)).to be_positive
    expect(store.meta('maintenance:last_backup')).to eq('2026-10-17')
  end

  it 'does not publish a temporary database that passes quick_check but lacks the application schema' do
    expect do
      store.atomic_backup(daily) do |path|
        copy = Sequel.sqlite(path)
        copy.create_table(:unrelated) { String :value }
        copy.disconnect
      end
    end.to raise_error(Sequel::DatabaseError, 'Backup validation failed')

    expect(File.exist?(daily)).to be(false)
    expect(Dir.glob(File.join(backups, '.muni-backup-*'))).to be_empty
  end

  it 'preserves capture age when a valid same-day file is verified again after a failed attempt' do
    allow(Time).to receive(:now).and_return(now)
    store.backup!(now: now)
    original = File.binread(daily)
    store.set_meta('maintenance:last_backup_failure', JSON.generate(at: (now + 60).iso8601))
    allow(Time).to receive(:now).and_return(now + 7200)
    store.backup!(now: now + 7200)

    expect(File.binread(daily)).to eq(original)
    expect(Muni::Status::Backup.snapshot(now: now + 7200)).to include(
      age_seconds: 7200, last_success_at: now.iso8601(6),
      last_verified_at: (now + 7200).iso8601(6), failure_state: 'recovered'
    )
  end

  it 'uses the existing file time when recovering a valid backup without retained capture metadata' do
    store.backup!(now: now)
    store.db[:meta].where(key: %w[maintenance:last_backup maintenance:last_backup_verified]).delete
    File.utime(now - 3600, now - 3600, daily)
    allow(Time).to receive(:now).and_return(now)
    store.backup!(now: now)

    expect(Muni::Status::Backup.snapshot(now: now)).to include(
      age_seconds: 3600, last_success_at: (now - 3600).iso8601(6), last_verified_at: now.iso8601(6)
    )
  end

  it 'publishes weekly copies atomically and retries without refreshing the daily capture' do
    sunday = Time.utc(2026, 10, 18, 12)
    weekly = File.join(backups, 'weekly-2026-W42.sqlite3')
    File.write(weekly, 'partial weekly copy')
    allow(FileUtils).to receive(:cp) do |_source, target|
      File.write(target, 'interrupted weekly copy')
      raise IOError, 'copy interrupted'
    end
    expect { store.backup!(now: sunday) }.to raise_error(IOError, 'copy interrupted')
    expect(File.read(weekly)).to eq('partial weekly copy')
    expect(Dir.glob(File.join(backups, '.muni-backup-*'))).to be_empty

    allow(FileUtils).to receive(:cp).and_call_original
    result = store.backup!(now: sunday)
    expect(File.binread(weekly)).to eq(File.binread(result))
    expect(store.valid_backup?(weekly)).to be(true)
  end
end
