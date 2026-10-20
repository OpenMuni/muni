require 'spec_helper'

RSpec.describe Muni::Accounts, '.ensure_schema!' do
  let(:db) { Muni::Store.db }
  let(:empty_station) { described_class::Preferences::EMPTY }
  let(:legacy_account) do
    { id: 'existing', issuer: 'https://issuer.example', subject: 'subject', email: 'user@example.test',
      preferred_hall: 'boston', status: 'active', revoked_before: 0, created_at: 1000, deleted_at: nil }
  end

  before do
    db.create_table(:accounts) do
      String :id, primary_key: true
      String :issuer, null: false
      String :subject, null: false
      String :email
      String :preferred_hall
      String :status, null: false, default: 'active'
      Integer :revoked_before, null: false, default: 0
      Integer :created_at, null: false
      Integer :deleted_at
      index %i[issuer subject], unique: true
    end
    db[:accounts].insert(legacy_account)
  end

  it 'adds nullable names through the writer lock while preserving legacy accounts and identity indexes' do
    allow(Muni::Store).to receive(:with_writer).and_call_original
    Muni::Store.ensure_tables!
    expect(Muni::Store).to have_received(:with_writer).once
    expect(db[:accounts][id: 'existing']).to eq(legacy_account.merge(empty_station, first_name: nil, last_name: nil))
    schema = db.schema(:accounts).to_h
    expect(schema[:first_name][:allow_null]).to be(true)
    expect(schema[:last_name][:allow_null]).to be(true)
    empty_station.each_key { |column| expect(schema[column][:allow_null]).to be(true) }
    expect { db[:accounts].insert(legacy_account.merge(id: 'duplicate')) }
      .to raise_error(Sequel::UniqueConstraintViolation)
  end

  it 'is repeatable and remains writable by old application code that omits names' do
    Muni::Store.ensure_tables!
    described_class.update_profile('existing', first_name: 'Élodie', last_name: '李')
    sid = described_class.create_session('existing', 'retained-ciphertext',
                                         { 'auth_time' => Time.now.to_i, 'exp' => Time.now.to_i + 300 })
    session_before = described_class.session_record(sid)
    Muni::Store.ensure_tables!
    expect(db[:accounts][id: 'existing']).to eq(legacy_account.merge(empty_station, first_name: 'Élodie',
                                                                                    last_name:  '李'))
    expect(described_class.session_record(sid)).to eq(session_before)
    db[:accounts].insert(legacy_account.merge(id: 'older-code', subject: 'second'))
    expect(db[:accounts][id: 'older-code']).to include(empty_station.merge(first_name: nil, last_name: nil))
    db[:accounts].where(id: 'existing').update(preferred_hall: 'cambridge')
    expect(db[:accounts][id: 'existing']).to include(preferred_hall: 'cambridge', first_name: 'Élodie')
  end

  it 'can finish a partially applied migration without rewriting existing profile data' do
    db.add_column(:accounts, :first_name, String)
    db.add_column(:accounts, :home_station_network, String)
    db[:accounts].update(first_name: 'Élodie')
    Muni::Store.ensure_tables!
    expect(db[:accounts][id: 'existing']).to eq(legacy_account.merge(empty_station, first_name: 'Élodie',
                                                                                    last_name:  nil))
  end
end
