require 'spec_helper'

RSpec.describe Muni::Status::Backup do
  let(:now) { Time.utc(2026, 10, 17, 12) }

  before do
    Muni::Store.ensure_tables!
    allow(Muni::Store).to receive(:maintenance_enabled?).and_return(true)
  end

  def metadata(key, value, at: now)
    Muni::Store.db[:meta].insert(key: "maintenance:#{key}", value: value, updated_at: at)
  end

  it 'reports legacy successful backup age and retention without inspecting backup files' do
    metadata('last_backup', '2026-10-16', at: now - 7200)
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:read).and_call_original

    expect(described_class.snapshot(now: now)).to include(
      status: 'current', age_seconds: 7200, last_backup_date: '2026-10-16',
      last_success_at: (now - 7200).iso8601(6), time_basis: 'maintenance_metadata',
      failure_state: 'none_recorded', retention: { daily: 7, weekly: 4 }
    )
    expect(File).not_to have_received(:exist?)
    expect(File).not_to have_received(:read)
  end

  it 'distinguishes overdue, unknown and intentionally disabled automatic backups' do
    expect(described_class.snapshot(now: now)[:status]).to eq('unknown')
    metadata('last_backup', '2026-10-15', at: now - (48 * 3600))
    expect(described_class.snapshot(now: now)[:status]).to eq('overdue')
    allow(Muni::Store).to receive(:maintenance_enabled?).and_return(false)
    expect(described_class.snapshot(now: now)).to include(status: 'disabled', age_seconds: 48 * 3600)
  end

  it 'retains a backup failure without exposing private error text and preserves the original exception' do
    failure = IOError.new('private backup path and contents')
    allow(FileUtils).to receive(:mkdir_p).and_raise(failure)
    expect { Muni::Store.backup!(now: now) }.to(raise_error { |error| expect(error).to equal(failure) })

    status = described_class.snapshot
    expect(status).to include(status: 'failed', failure_state: 'failed', last_success_at: nil)
    expect(status[:last_failure_at]).not_to be_nil
    expect(JSON.generate(status)).not_to include('private', 'IOError')
  end

  it 'does not mask the original failure when recording failure metadata also fails' do
    failure = IOError.new('original backup failure')
    allow(FileUtils).to receive(:mkdir_p).and_raise(failure)
    allow(Muni::Store).to receive(:set_meta).and_raise(Sequel::DatabaseError, 'metadata unavailable')

    expect { Muni::Store.backup! }.to(raise_error { |error| expect(error).to equal(failure) })
  end

  it 'records a successful backup and distinguishes recovery within the same second' do
    Dir.mktmpdir('backup-status') do |directory|
      original = ENV.fetch('MUNI_BACKUP_PATH', nil)
      ENV['MUNI_BACKUP_PATH'] = directory
      metadata('last_backup_failure', JSON.generate(at: '2026-10-17T12:00:00.100000Z', error_class: 'IOError'))
      allow(Time).to receive(:now).and_return(now + 0.2)
      Muni::Store.backup!(now: now)

      expect(described_class.snapshot(now: now + 1)).to include(
        status: 'current', failure_state: 'recovered', last_success_at: '2026-10-17T12:00:00.200000Z',
        age_seconds: 0, last_backup_date: '2026-10-17'
      )
    ensure
      original ? ENV['MUNI_BACKUP_PATH'] = original : ENV.delete('MUNI_BACKUP_PATH')
    end
  end
end
