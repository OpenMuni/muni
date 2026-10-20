require 'spec_helper'

RSpec.describe Muni::Accounts, '.preference' do
  let(:claims) do
    { 'iss' => 'https://issuer.example', 'sub' => 'subject', 'email' => 'user@example.test',
      'auth_time' => Time.now.to_i, 'exp' => Time.now.to_i + 300 }
  end
  let(:account) { described_class.resolve(claims) }

  before do
    Muni::Store.ensure_tables!
    allow(Muni::Transit).to receive(:stations).and_return(
      'data' => [{ 'id' => 'place-pktrm', 'routes' => %w[Red Green-B Green-C Green-D Green-E] }]
    )
  end

  def save_station
    described_class.preference(account[:id], 'boston', line: 'Green-B', station: 'place-pktrm')
  end

  it 'fetches station data outside the database writer and writes all fields under one lock' do
    account
    allow(Muni::Store).to receive(:with_writer).and_call_original
    save_station
    expect(Muni::Transit).to have_received(:stations).ordered
    expect(Muni::Store).to have_received(:with_writer).ordered
    expect(described_class.account(account[:id])).to include(home_station_id: 'place-pktrm', preferred_hall: 'boston')
  end

  it 'clears the old network when a future public city is selected by a city-only client' do
    save_station
    other = Muni::Hall.new(slug: 'future-city', name: 'Future city')
    allow(Muni::Hall).to receive(:all).and_return(Muni::Hall.all + [other])
    described_class.preference(account[:id], 'future-city')
    expect(described_class.account(account[:id])).to include(
      described_class::Preferences::EMPTY.merge(preferred_hall: 'future-city')
    )
    expect do
      described_class.preference(account[:id], 'future-city', line: 'Green-B', station: 'place-pktrm')
    end.to raise_error(described_class::InvalidPreference, /MBTA train line/)
  end

  it 'does not overwrite preferences from Cognito claims or merge accounts by email' do
    save_station
    changed = described_class.resolve(claims.merge('home_station_id' => 'place-harsq', 'preferred_hall' => 'cambridge'))
    expect(changed).to include(id: account[:id], preferred_hall: 'boston', home_station_id: 'place-pktrm')
    other = described_class.resolve(claims.merge('iss' => 'https://other.example'))
    expect(other[:id]).not_to eq(account[:id])
    expect(other).to include(described_class::Preferences::EMPTY.merge(preferred_hall: nil))
  end

  it 'preserves preferences through repeatable migration and legacy city-only writes' do
    save_station
    Muni::Store.ensure_tables!
    described_class.preference(account[:id], 'cambridge')
    expect(described_class.account(account[:id])).to include(
      preferred_hall: 'cambridge', home_station_network: 'mbta',
      home_station_line: 'Green-B', home_station_id: 'place-pktrm'
    )
  end

  it 'clears preferences on pending deletion and cannot restore them with a late write' do
    save_station
    described_class.deletion_pending(account[:id])
    expect(save_station).to eq(0)
    expect(described_class.account(account[:id])).to include(
      described_class::Preferences::EMPTY.merge(preferred_hall: nil, status: 'deletion_pending')
    )
  end

  it 'includes preferences in existing backups and leaves retained snapshots immutable on deletion' do
    save_station
    Dir.mktmpdir('account-backup') do |directory|
      path = File.join(directory, 'snapshot.sqlite3')
      Muni::Store.online_backup(path)
      digest = Digest::SHA256.file(path).hexdigest
      described_class.deletion_pending(account[:id])
      backup = Sequel.sqlite(path, readonly: true)
      expect(backup[:accounts][id: account[:id]]).to include(
        home_station_network: 'mbta', home_station_line: 'Green-B', home_station_id: 'place-pktrm'
      )
      expect(Digest::SHA256.file(path).hexdigest).to eq(digest)
      expect(Muni::Store::BACKUP_DAILY_RETENTION).to eq(7)
      expect(Muni::Store::BACKUP_WEEKLY_RETENTION).to eq(4)
    ensure
      backup&.disconnect
    end
  end
end
