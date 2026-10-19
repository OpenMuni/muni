require 'spec_helper'

RSpec.describe Muni::Status::ExternalBackup do
  let(:now) { Time.utc(2026, 10, 19, 12) }
  let(:evidence) do
    { schema_version: 1, captured_at: (now - 7200).iso8601, verified_at: (now - 3600).iso8601,
      last_failure_at: nil, retention: { local_snapshots: 2, s3_days: 60 },
      name: 'private-key', sha256: 'private-checksum', bucket: 'private-bucket' }
  end

  around do |example|
    keys = %w[MUNI_BACKUP_MODE MUNI_BACKUP_STATUS_PATH MUNI_MAINTENANCE_ENABLED]
    previous = keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    Dir.mktmpdir('external-backup') do |directory|
      ENV['MUNI_BACKUP_MODE'] = 'external'
      ENV['MUNI_BACKUP_STATUS_PATH'] = File.join(directory, 'status.json')
      File.write(ENV.fetch('MUNI_BACKUP_STATUS_PATH'), JSON.generate(evidence))
      example.run
    end
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  def status = Muni::Status::Backup.snapshot(now: now)

  it 'reports capture age and S3 verification without exposing private evidence' do
    ENV['MUNI_MAINTENANCE_ENABLED'] = '0'
    expect(status).to include(status: 'current', backend: 'external', age_seconds: 7200,
                              last_success_at: (now - 7200).iso8601(6), verification: 's3_checksum',
                              retention: { daily: 0, weekly: 0, local_snapshots: 2, s3_days: 60 })
    expect(JSON.generate(status)).not_to include('private', ENV.fetch('MUNI_BACKUP_STATUS_PATH'))
  end

  it 'reports overdue evidence even when its upload was recent' do
    evidence[:captured_at] = (now - (27 * 3600)).iso8601
    File.write(ENV.fetch('MUNI_BACKUP_STATUS_PATH'), JSON.generate(evidence))
    expect(status[:status]).to eq('overdue')
  end

  it 'reports a failed first attempt and recovery after a later verified upload' do
    evidence[:last_failure_at] = (now - 1800).iso8601
    File.write(ENV.fetch('MUNI_BACKUP_STATUS_PATH'), JSON.generate(evidence))
    expect(status).to include(status: 'failed', failure_state: 'failed')
    evidence[:captured_at] = nil
    evidence[:verified_at] = nil
    File.write(ENV.fetch('MUNI_BACKUP_STATUS_PATH'), JSON.generate(evidence))
    expect(status[:status]).to eq('failed')
    evidence[:captured_at] = (now - 1200).iso8601
    evidence[:verified_at] = (now - 600).iso8601
    File.write(ENV.fetch('MUNI_BACKUP_STATUS_PATH'), JSON.generate(evidence))
    expect(status).to include(status: 'current', failure_state: 'recovered')
  end

  it 'fails closed for missing, malformed, future and inconsistent evidence' do
    path = ENV.fetch('MUNI_BACKUP_STATUS_PATH')
    File.unlink(path)
    expect(status[:status]).to eq('unknown')
    [[], {}, 'broken', evidence.merge(captured_at: (now + 3600).iso8601),
     evidence.merge(verified_at: nil), evidence.merge(retention: { local_snapshots: '2' })].each do |value|
      File.write(path, value.is_a?(String) ? value : JSON.generate(value))
      expect(status).to include(status: 'unknown', backend: 'external')
    end
  end

  it 'disables backups independently of maintenance and rejects invalid modes' do
    ENV['MUNI_BACKUP_MODE'] = 'disabled'
    ENV['MUNI_MAINTENANCE_ENABLED'] = '1'
    expect(status).to include(status: 'disabled', enabled: false)
    expect(Muni::Store.maintenance_enabled?).to be(true)
    ENV['MUNI_BACKUP_MODE'] = 'typo'
    expect { Muni::Store.backup_mode }.to raise_error(ArgumentError)
  end

  it 'skips automatic local snapshots but still runs weekly optimization in external and disabled modes' do
    Muni::Store.ensure_tables!
    ENV['MUNI_MAINTENANCE_ENABLED'] = '1'
    allow(Muni::Store).to receive(:backup!)
    allow(Muni::Store).to receive(:optimize!)
    %w[external disabled].each_with_index do |mode, week|
      ENV['MUNI_BACKUP_MODE'] = mode
      Muni::Store.perform_maintenance!(now: Time.utc(2026, 10, 18) + (week * 7 * 86_400))
    end
    expect(Muni::Store).not_to have_received(:backup!)
    expect(Muni::Store).to have_received(:optimize!).twice
  end
end
