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

  it 'keeps names local and resolves identity exclusively by issuer and subject' do
    account = described_class.resolve(claims)
    described_class.update_profile(account[:id], first_name: 'Élodie', last_name: '李')
    same = described_class.resolve(claims.merge('email' => 'changed@example.test', 'given_name' => 'Untrusted'))
    expect(same).to include(id: account[:id], first_name: 'Élodie', last_name: '李')
    other_subject = described_class.resolve(claims.merge('sub' => 'other'))
    other_issuer = described_class.resolve(claims.merge('iss' => 'https://other.example'))
    expect([account[:id], other_subject[:id], other_issuer[:id]].uniq.length).to eq(3)
    expect(other_subject).to include(first_name: nil, last_name: nil)
  end

  it 'rejects invalid text encodings before any profile write' do
    account = described_class.resolve(claims)
    expect do
      described_class.update_profile(account[:id], first_name: "\xff".force_encoding('UTF-8'), last_name: 'Name')
    end.to raise_error(described_class::InvalidProfile, 'First name must be valid text.')
    expect(described_class.account(account[:id])[:first_name]).to be_nil
  end

  it 'does not restore profile data after deletion begins' do
    account = described_class.resolve(claims)
    described_class.update_profile(account[:id], first_name: 'First', last_name: 'Last')
    described_class.deletion_pending(account[:id])
    expect(described_class.update_profile(account[:id], first_name: 'Late', last_name: 'Write')).to eq(0)
    expect(described_class.account(account[:id])).to include(first_name: nil, last_name: nil)
  end
end
