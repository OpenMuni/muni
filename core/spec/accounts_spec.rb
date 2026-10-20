require 'spec_helper'

RSpec.describe Muni::Accounts do
  let(:claims) do
    { 'iss' => 'https://issuer.example', 'sub' => 'subject', 'email' => 'user@example.test',
      'auth_time' => Time.now.to_i, 'exp' => Time.now.to_i + 300 }
  end

  before { Muni::Store.ensure_tables! }

  it 'enforces idle and absolute expiration independently' do
    account = described_class.resolve(claims)
    sid = described_class.create_session(account[:id], 'ciphertext', claims, now: 1000)
    expect(described_class.session(sid, now: 1001)).not_to be_nil
    expect(described_class.session(sid, now: 87_401)).to be_nil
    described_class.touch(sid, now: 605_799)
    expect(described_class.session(sid, now: 605_801)).to be_nil
  end

  it 'allows one refresh owner and cannot resurrect a session revoked during refresh' do
    account = described_class.resolve(claims)
    sid = described_class.create_session(account[:id], 'ciphertext', claims)
    expect(described_class.claim_refresh(sid, 'first')).to be(true)
    expect(described_class.claim_refresh(sid, 'second')).to be(false)
    described_class.revoke_all(account[:id])
    expect(described_class.finish_refresh(sid, 'first', 'replacement', Time.now.to_i + 300)).to be(false)
    expect(described_class.resolve(claims)).to be_nil
  end

  it 'keeps account schema additive and recognized by maintenance' do
    before = Muni::Store.db.tables
    described_class.ensure_schema!
    expect(Muni::Store.db.tables).to eq(before)
    expect(Muni::Store::OPERATIONAL_TABLES).to include(:accounts, :account_sessions, :account_auth_transactions)
  end
end
