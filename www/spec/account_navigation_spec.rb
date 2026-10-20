require_relative 'support/accounts'

RSpec.describe 'Public account navigation' do
  include_context 'with Cognito accounts'

  before do
    allow(Muni::Www::Auth).to receive(:mode).and_return('public')
    allow(Muni::Water).to receive_messages(enabled?: true, presentation_enabled?: true)
  end

  ['/?hall=cambridge', '/?hall=boston', '/about', '/dashboard', '/trends', '/digest',
   '/meetings', '/mobility/subway', '/water/charles', '/status'].each do |path|
    it "provides uncached, signed-out Login navigation on #{path} without Cognito" do
      allow(Muni::Www::Auth).to receive(:service).and_raise(Muni::Www::Auth::Unavailable)
      get "https://muni.example#{path}"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('href="/login">Login</a>', 'aria-label="Site"',
                                            '/css/account-navigation.css')
      expect(last_response.body).not_to include('href="/account"')
      expect(last_response.headers['cache-control']).to eq('no-store, private')
      expect(last_response.headers['vary']).to include('Cookie')
      expect(Muni::Www::Auth).not_to have_received(:service)
    end
  end

  it 'links the saved first name to Account without any provider call during public browsing' do
    row = sign_in
    Muni::Accounts.update_profile(row[:account_id], first_name: 'Élodie', last_name: '李')
    Muni::Store.db[:account_sessions].update(token_expires_at: 0)
    allow(Muni::Www::Auth).to receive(:service).and_raise(Muni::Www::Auth::Unavailable)
    get 'https://muni.example/'
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('href="/account"', '<bdi>Élodie</bdi>')
    expect(last_response.body).not_to include('href="/login"', 'resident@example.test')
    expect(last_response.headers['cache-control']).to eq('no-store, private')
    expect(last_response.headers['vary']).to include('Cookie')
  end

  it 'shows Account for an existing session without a first name' do
    sign_in
    get 'https://muni.example/'
    expect(last_response.body).to include('href="/account"', '<bdi>Account</bdi>')
    expect(last_response.body).not_to include('href="/login"')
  end

  it 'does not reuse one visitor’s name for another visitor or an anonymous request' do
    first = sign_in
    Muni::Accounts.update_profile(first[:account_id], first_name: 'Alice', last_name: 'Resident')
    get 'https://muni.example/about'
    expect(last_response.body).to include('<bdi>Alice</bdi>')
    clear_cookies
    get 'https://muni.example/about'
    expect(last_response.body).to include('href="/login">Login</a>')
    expect(last_response.body).not_to include('Alice')
    allow(provider).to receive(:validate).and_return(claims.merge('sub' => 'other'))
    second = sign_in
    Muni::Accounts.update_profile(second[:account_id], first_name: 'Bob', last_name: 'Resident')
    get 'https://muni.example/about'
    expect(last_response.body).to include('<bdi>Bob</bdi>')
    expect(last_response.body).not_to include('Alice')
  end

  [{ expires_at: 0 }, { idle_until: 0 }].each do |expiration|
    it "shows Login when the local session has expired (#{expiration.keys.first})" do
      sign_in
      Muni::Store.db[:account_sessions].update(expiration)
      get 'https://muni.example/'
      expect(last_response.body).to include('href="/login">Login</a>')
    end
  end

  [{ status: 'deletion_pending' }, { status: 'deleted' }, { revoked_before: Time.now.to_i + 60 }].each do |state|
    it "does not personalize navigation for a disabled or revoked account (#{state.keys.first})" do
      sign_in
      Muni::Store.db[:accounts].update(state.merge(first_name: 'Hidden'))
      get 'https://muni.example/'
      expect(last_response.body).to include('href="/login">Login</a>')
      expect(last_response.body).not_to include('<bdi>Hidden</bdi>')
    end
  end

  it 'ignores forged session cookies and keeps municipal APIs free of names' do
    row = sign_in
    Muni::Accounts.update_profile(row[:account_id], first_name: 'PrivateNameMarker', last_name: 'Resident')
    get 'https://muni.example/api/halls'
    expect(last_response.status).to eq(200)
    expect(last_response.body).not_to include('PrivateNameMarker', 'first_name')
    clear_cookies
    get 'https://muni.example/', {}, 'HTTP_COOKIE' => "__Host-muni_session=#{row[:account_id]}"
    expect(last_response.body).to include('href="/login">Login</a>')
    expect(last_response.body).not_to include('PrivateNameMarker')
  end

  it 'keeps public pages available when account storage is temporarily unavailable' do
    sign_in
    allow(Muni::Accounts).to receive(:session).and_raise(Sequel::DatabaseError)
    get 'https://muni.example/about'
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('href="/login">Login</a>')
    expect(last_response.headers['cache-control']).to eq('no-store, private')
  end

  %w[off pilot public].each do |mode|
    it "honors #{mode} mode for navigation and profile routes" do
      sign_in
      allow(Muni::Www::Auth).to receive(:mode).and_return(mode)
      get 'https://muni.example/'
      expect(last_response.status).to eq(200)
      if mode == 'public'
        expect(last_response.body).to include('href="/account"')
      else
        expect(last_response.body).not_to include('href="/login"', 'href="/account"')
      end
      get 'https://muni.example/account'
      expect(last_response.status).to eq(mode == 'off' ? 404 : 200)
      submit '/account/profile', first_name: 'Mode', last_name: 'Test'
      expect(last_response.status).to eq(mode == 'off' ? 404 : 303)
      get 'https://muni.example/login'
      expect(last_response.status).to eq(mode == 'off' ? 404 : 302)
    end
  end
end
