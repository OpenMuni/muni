require 'spec_helper'
require 'uri'

RSpec.describe 'Cognito account routes' do
  def app = Muni::Www::App

  let(:claims) do
    { 'iss' => config.issuer, 'sub' => 'subject-one', 'email' => 'resident@example.test',
      'email_verified' => true, 'auth_time' => Time.now.to_i, 'exp' => Time.now.to_i + 300 }
  end
  let(:tokens) do
    { 'access_token' => 'private-access-marker', 'id_token' => 'id', 'refresh_token' => 'private-refresh-marker' }
  end
  let(:config) do
    Muni::Www::Auth::Config.new(
      'MUNI_PUBLIC_BASE_URL' => 'https://muni.example', 'MUNI_COGNITO_DOMAIN' => 'https://auth.muni.example',
      'MUNI_COGNITO_POOL_ID' => 'us-east-1_example', 'MUNI_COGNITO_CLIENT_ID' => 'client',
      'MUNI_COGNITO_CLIENT_SECRET' => 'fixture-only', 'MUNI_AUTH_ENCRYPTION_KEY' => Base64.strict_encode64('k' * 32)
    )
  end
  let(:provider) do
    instance_double(Muni::Www::Auth::Provider, exchange: tokens, validate: claims, verify_user: nil,
                                            credentials: [], global_sign_out: nil, revoke: nil,
                                            enrollment_url: 'https://auth.muni.example/passkeys/add?client_id=client',
                                            logout_url: 'https://auth.muni.example/logout', delete_user: nil)
  end
  let(:service) { Muni::Www::Auth::Service.new(config, provider: provider) }

  before do
    Muni::Store.ensure_tables!
    allow(Muni::Www::Auth).to receive_messages(mode: 'pilot', service: service, passkeys_enabled?: true)
    allow(provider).to receive(:authorize) do |_transaction, state, path:|
      "https://auth.muni.example#{path}?state=#{state}"
    end
  end

  def start(path = '/login')
    get "https://muni.example#{path}"
    URI.decode_www_form(URI(last_response.location).query).to_h.fetch('state')
  end

  def sign_in
    state = start
    get 'https://muni.example/auth/cognito/callback', state: state, code: 'one-use-code'
    Muni::Accounts.session(rack_mock_session.cookie_jar['__Host-muni_session'])
  end

  def submit(path, attributes = {})
    row = Muni::Accounts.session(rack_mock_session.cookie_jar['__Host-muni_session'])
    post "https://muni.example#{path}", { csrf: row&.fetch(:csrf) }.merge(attributes),
         'HTTP_ORIGIN' => 'https://muni.example'
  end

  def begin_enrollment
    sign_in
    submit '/account/passkeys'
    state = URI.decode_www_form(URI(last_response.location).query).to_h.fetch('state')
    get 'https://muni.example/auth/cognito/callback', state: state, code: 'reauth-code'
    rack_mock_session.cookie_jar['__Host-muni_session']
  end

  it 'establishes an encrypted server-side session with a host-only secure cookie' do
    row = sign_in
    expect(last_response.location).to end_with('/account')
    expect(last_response.headers['set-cookie'].join).to include('secure', 'httponly', 'samesite=lax')
    expect(last_response.headers['set-cookie'].join.downcase).not_to include('domain=')
    expect(row[:tokens]).not_to include('private-access-marker', 'private-refresh-marker')
    expect(row[:account][:subject]).to eq('subject-one')
    expect(row[:expires_at] - Time.now.to_i).to be_within(2).of(604_800)
  end

  it 'binds callbacks to their initiating browser and consumes successful state once' do
    state = start
    get 'https://muni.example/auth/cognito/callback', state: 'wrong', code: 'code'
    expect(last_response.status).to eq(400)
    get 'https://muni.example/auth/cognito/callback', state: state, code: 'code'
    expect(last_response.status).to eq(302)
    get 'https://muni.example/auth/cognito/callback', state: state, code: 'code'
    expect(last_response.status).to eq(400)
  end

  it 'rejects a callback copied to another browser' do
    state = start
    clear_cookies
    get 'https://muni.example/auth/cognito/callback', state: state, code: 'code'
    expect(last_response.status).to eq(400)
    expect(provider).not_to have_received(:exchange)
  end

  it 'rejects expired transactions' do
    state = start
    Muni::Store.db[:account_auth_transactions].update(expires_at: Time.now.to_i - 1)
    get 'https://muni.example/auth/cognito/callback', state: state, code: 'code'
    expect(last_response.status).to eq(400)
  end

  it 'rotates the application session on another successful sign-in' do
    sign_in
    previous = rack_mock_session.cookie_jar['__Host-muni_session']
    sign_in
    expect(Muni::Accounts.session(previous)).to be_nil
    expect(rack_mock_session.cookie_jar['__Host-muni_session']).not_to eq(previous)
    expect(Muni::Store.db[:accounts].count).to eq(1)
  end

  it 'does not merge accounts that share an email address' do
    sign_in
    allow(provider).to receive(:validate).and_return(claims.merge('sub' => 'another-subject'))
    sign_in
    expect(Muni::Store.db[:accounts].count).to eq(2)
  end

  it 'does not grant access through a bare account identifier, legacy cookie, or matching email' do
    row = sign_in
    clear_cookies
    get 'https://muni.example/account', { user_id: row[:account_id], email: claims['email'] },
        'HTTP_COOKIE' => "muni_session=legacy; __Host-muni_session=#{row[:account_id]}"
    expect(last_response.status).to eq(302)
    expect(last_response.location).to end_with('/login')
    expect(provider).not_to have_received(:credentials)
  end

  it 'rejects cross-account reauthentication before passkey enrollment' do
    row = sign_in
    submit '/account/passkeys'
    state = URI.decode_www_form(URI(last_response.location).query).to_h.fetch('state')
    allow(provider).to receive(:validate).and_return(claims.merge('sub' => 'another-subject'))
    get 'https://muni.example/auth/cognito/callback', state: state, code: 'code'
    expect(last_response.status).to eq(400)
    expect(Muni::Store.db[:accounts].select_map(:id)).to eq([row[:account_id]])
  end

  it 'requires a fresh Cognito sign-in before hosted passkey enrollment' do
    begin_enrollment
    expect(last_response.location).to start_with('https://auth.muni.example/passkeys/add?')
    expect(last_response.headers['set-cookie'].join).to include('__Host-muni_enrollment=', 'max-age=600',
                                                                'secure', 'httponly', 'samesite=lax')
  end

  it 'handles the real hosted enrollment result without exchanging a code or creating another session' do
    sid = begin_enrollment
    allow(provider).to receive(:credentials).and_return([{ credential_id: 'platform-key' }])
    get 'https://muni.example/auth/passkeys/complete', result: 'success'
    expect(last_response.status).to eq(303)
    expect(last_response.location).to end_with('/account')
    expect(provider).to have_received(:credentials).with(tokens).once
    expect(provider).to have_received(:exchange).exactly(2).times
    expect(rack_mock_session.cookie_jar['__Host-muni_session']).to eq(sid)
    expect(Muni::Store.db[:account_sessions].count).to eq(1)
    expect(Muni::Store.db[:accounts].count).to eq(1)
    get 'https://muni.example/auth/passkeys/complete', result: 'success'
    expect(last_response.status).to eq(400)
    expect(provider).to have_received(:credentials).once
  end

  it 'does not trust an enrollment result as proof of authentication' do
    get 'https://muni.example/auth/passkeys/complete', result: 'success'
    expect(last_response.status).to eq(400)
    expect(Muni::Store.db[:account_sessions].count).to eq(0)
    expect(Muni::Store.db[:accounts].count).to eq(0)
    expect(provider).not_to have_received(:exchange)
    expect(provider).not_to have_received(:credentials)
    get 'https://muni.example/auth/cognito/callback', result: 'success'
    expect(last_response.status).to eq(400)
  end

  it 'returns safely to settings when enrollment adds no credential, regardless of the result query' do
    begin_enrollment
    get 'https://muni.example/auth/passkeys/complete', result: 'canceled'
    expect(last_response.location).to end_with('/account')
    follow_redirect!
    expect(last_response.body).to include('No passkeys registered.', 'Your password remains available.')
    expect(Muni::Store.db[:accounts].count).to eq(1)
  end

  it 'rejects an enrollment return with no browser receipt or an expired receipt' do
    begin_enrollment
    receipt = rack_mock_session.cookie_jar['__Host-muni_enrollment']
    rack_mock_session.cookie_jar.delete('__Host-muni_enrollment')
    get 'https://muni.example/auth/passkeys/complete', result: 'success'
    expect(last_response.status).to eq(400)
    rack_mock_session.cookie_jar['__Host-muni_enrollment'] = receipt
    Muni::Store.db[:account_auth_transactions].update(expires_at: Time.now.to_i - 1)
    get 'https://muni.example/auth/passkeys/complete', result: 'success'
    expect(last_response.status).to eq(400)
    expect(provider).not_to have_received(:credentials)
  end

  it 'rejects enrollment completion from another session even for the same account' do
    begin_enrollment
    sign_in
    get 'https://muni.example/auth/passkeys/complete', result: 'success'
    expect(last_response.status).to eq(400)
    expect(provider).not_to have_received(:credentials)
    expect(Muni::Store.db[:accounts].count).to eq(1)
  end

  it 'rejects enrollment completion after the browser changes accounts' do
    begin_enrollment
    allow(provider).to receive(:validate).and_return(claims.merge('sub' => 'another-subject'))
    sign_in
    get 'https://muni.example/auth/passkeys/complete', result: 'success'
    expect(last_response.status).to eq(400)
    expect(provider).not_to have_received(:credentials)
  end

  it 'rejects enrollment completion after the account sessions are revoked' do
    sid = begin_enrollment
    Muni::Accounts.revoke_all(Muni::Accounts.session(sid)[:account_id])
    get 'https://muni.example/auth/passkeys/complete', result: 'success'
    expect(last_response.status).to eq(400)
    expect(provider).not_to have_received(:credentials)
    expect(Muni::Store.db[:account_sessions].count).to eq(0)
  end

  it 'fails closed on a credential-list outage without removing the signed-in account' do
    sid = begin_enrollment
    allow(provider).to receive(:credentials).and_raise(Muni::Www::Auth::Unavailable)
    get 'https://muni.example/auth/passkeys/complete', result: 'success'
    expect(last_response.status).to eq(503)
    expect(Muni::Accounts.session(sid)).not_to be_nil
  end

  it 'requires CSRF and matching origin to change a preference' do
    row = sign_in
    post 'https://muni.example/account/preference', { hall: 'boston', csrf: row[:csrf] },
         'HTTP_ORIGIN' => 'https://attacker.example'
    expect(last_response.status).to eq(403)
    submit '/account/preference', hall: 'boston', csrf: 'forged'
    expect(last_response.status).to eq(403)
    submit '/account/preference', hall: 'boston'
    expect(last_response.status).to eq(303)
    expect(Muni::Accounts.account(row[:account_id])[:preferred_hall]).to eq('boston')
  end

  it 'rejects forged hosts and untrusted forwarded HTTPS' do
    get 'https://attacker.example/login'
    expect(last_response.status).to eq(400)
    get 'http://muni.example/login', {}, 'REMOTE_ADDR' => '192.0.2.7', 'HTTP_X_FORWARDED_PROTO' => 'https'
    expect(last_response.status).to eq(400)
  end

  it 'accepts privacy-preserving same-origin browser forms only with a valid CSRF token' do
    row = sign_in
    headers = { 'HTTP_ORIGIN' => 'null', 'HTTP_SEC_FETCH_SITE' => 'same-origin' }
    post 'https://muni.example/account/preference', { hall: 'boston', csrf: 'forged' }, headers
    expect(last_response.status).to eq(403)
    post 'https://muni.example/account/preference', { hall: 'boston', csrf: row[:csrf] }, headers
    expect(last_response.status).to eq(303)
    expect(Muni::Accounts.account(row[:account_id])[:preferred_hall]).to eq('boston')
    post 'https://muni.example/logout', { csrf: row[:csrf] }, headers
    expect(last_response.location).to eq('https://auth.muni.example/logout')
    expect(Muni::Store.db[:account_sessions].count).to eq(0)
  end

  it 'rejects opaque, missing, or foreign form origins without trustworthy same-origin metadata' do
    row = sign_in
    [nil, 'same-site', 'cross-site', 'none'].each do |site|
      post 'https://muni.example/account/preference', { hall: 'boston', csrf: row[:csrf] },
           'HTTP_ORIGIN' => 'null', 'HTTP_SEC_FETCH_SITE' => site
      expect(last_response.status).to eq(403)
    end
    [nil, 'https://attacker.example'].each do |origin|
      post 'https://muni.example/account/preference', { hall: 'boston', csrf: row[:csrf] },
           'HTTP_ORIGIN' => origin, 'HTTP_SEC_FETCH_SITE' => 'same-origin'
      expect(last_response.status).to eq(403)
    end
  end

  it 'ignores external return URLs' do
    start('/login?return_to=https://attacker.example')
    expect(last_response.location).not_to include('attacker.example')
  end

  it 'keeps tokens and account details out of caches and browser markup' do
    sign_in
    get 'https://muni.example/account'
    expect(last_response.status).to eq(200)
    expect(last_response.headers['cache-control']).to include('no-store')
    expect(last_response.headers['content-security-policy']).to include("frame-ancestors 'none'")
    expect(last_response.body).not_to include('private-access-marker', 'private-refresh-marker')
  end

  it 'allows form redirects only to this application and its configured Cognito origin' do
    sign_in
    get 'https://muni.example/account'
    policy = last_response.headers['content-security-policy'].split(';').map(&:strip)
    form_sources = policy.find { |directive| directive.start_with?('form-action ') }.split.drop(1)
    expect(form_sources).to eq(["'self'", config.domain])

    %w[/account/passkeys /logout].each do |path|
      submit path
      destination = URI(last_response.location)
      expect(form_sources).to include("#{destination.scheme}://#{destination.host}")
    end
  end

  it 'removes only a credential listed for the authenticated user, including the last one' do
    sign_in
    allow(provider).to receive(:credentials).and_return([{ credential_id:            'owned',
                                                           friendly_credential_name: 'Laptop' }])
    allow(provider).to receive(:remove_credential)
    submit '/account/passkeys/remove', credential_id: 'someone-elses'
    expect(last_response.status).to eq(422)
    submit '/account/passkeys/remove', credential_id: 'owned'
    expect(last_response.status).to eq(303)
    expect(provider).to have_received(:remove_credential).with(tokens, 'owned').once
  end

  it 'requires reauthentication for stale sensitive operations without executing them' do
    sign_in
    Muni::Store.db[:account_sessions].update(auth_time: Time.now.to_i - 301)
    submit '/account/delete', confirm: 'delete'
    expect(last_response.location).to start_with('https://auth.muni.example/oauth2/authorize')
    expect(provider).not_to have_received(:delete_user)
  end

  it 'invalidates local sessions during recovery and clears the Cognito browser session' do
    row = sign_in
    state = start('/recover')
    get 'https://muni.example/auth/cognito/callback', state: state, code: 'recovery-code'
    expect(last_response.location).to eq('https://auth.muni.example/logout')
    expect(Muni::Store.db[:account_sessions].where(account_id: row[:account_id]).count).to eq(0)
    expect(provider).to have_received(:global_sign_out).with(tokens)
  end

  it 'signs out locally even when provider revocation fails' do
    sign_in
    previous = rack_mock_session.cookie_jar['__Host-muni_session']
    allow(provider).to receive(:revoke).and_raise(Muni::Www::Auth::Unavailable)
    submit '/logout'
    expect(last_response.status).to eq(303)
    expect(Muni::Accounts.session(previous)).to be_nil
    expect(last_response.location).to eq('https://auth.muni.example/logout')
  end

  it 'can sign out without refreshing an expired access token during a provider outage' do
    sign_in
    token = rack_mock_session.cookie_jar['__Host-muni_session']
    Muni::Store.db[:account_sessions].update(token_expires_at: Time.now.to_i - 1)
    allow(provider).to receive(:refresh).and_raise(Muni::Www::Auth::Unavailable)
    allow(provider).to receive(:revoke).and_raise(Muni::Www::Auth::Unavailable)
    submit '/logout', csrf: 'forged'
    expect(last_response.status).to eq(403)
    expect(Muni::Accounts.session(token)).not_to be_nil
    submit '/logout'
    expect(last_response.status).to eq(303)
    expect(Muni::Accounts.session_record(token)).to be_nil
    expect(provider).not_to have_received(:refresh)
  end

  it 'revokes local sessions before a failed global provider sign-out' do
    sign_in
    Muni::Store.db[:account_sessions].update(token_expires_at: Time.now.to_i - 1)
    allow(provider).to receive(:global_sign_out).and_raise(Muni::Www::Auth::Unavailable)
    submit '/logout-all'
    expect(last_response.status).to eq(503)
    expect(Muni::Store.db[:account_sessions].count).to eq(0)
  end

  it 'retains a disabled deletion record when the provider is unavailable' do
    row = sign_in
    Muni::Store.db[:account_sessions].update(token_expires_at: Time.now.to_i - 1)
    allow(provider).to receive(:refresh).and_raise(Muni::Www::Auth::Unavailable)
    allow(provider).to receive(:delete_user).and_raise(Muni::Www::Auth::Unavailable)
    submit '/account/delete', confirm: 'delete'
    expect(last_response.status).to eq(503)
    expect(Muni::Accounts.account(row[:account_id])).to include(status: 'deletion_pending', email: nil)
    expect(Muni::Store.db[:account_sessions].count).to eq(0)
    expect(Muni::Accounts.resolve(claims)).to be_nil
    expect(provider).not_to have_received(:refresh)
  end

  it 'deletes account data while retaining only a non-reusable identity tombstone' do
    row = sign_in
    submit '/account/delete', confirm: 'delete'
    expect(last_response.status).to eq(303)
    expect(Muni::Accounts.account(row[:account_id])).to include(status: 'deleted', email: nil, preferred_hall: nil)
    expect(provider).to have_received(:delete_user).with(tokens)
  end

  it 'preserves public pages when authentication is unavailable or disabled' do
    allow(Muni::Www::Auth).to receive(:service).and_raise(Muni::Www::Auth::Unavailable)
    get '/healthz'
    expect(last_response.status).to eq(200)
    %w[cambridge boston].each do |hall|
      get '/', hall: hall
      expect(last_response.status).to eq(200)
    end
    allow(Muni::Www::Auth).to receive(:mode).and_return('off')
    get '/login'
    expect(last_response.status).to eq(404)
  end

  it 'keeps the password pilot usable without listing or enrolling passkeys' do
    allow(Muni::Www::Auth).to receive(:passkeys_enabled?).and_return(false)
    sign_in
    get 'https://muni.example/account'
    expect(last_response.status).to eq(200)
    expect(last_response.body).not_to include('Add a passkey')
    expect(provider).not_to have_received(:credentials)
    submit '/account/passkeys'
    expect(last_response.status).to eq(404)
  end

  it 'shows public account navigation without contacting Cognito and hides it during the pilot' do
    allow(Muni::Www::Auth).to receive(:service).and_raise(Muni::Www::Auth::Unavailable)
    allow(Muni::Www::Auth).to receive(:mode).and_return('public')
    ['/?hall=cambridge', '/mobility/subway?hall=boston'].each do |path|
      get path
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('href="/login"', 'href="/signup"', 'href="/account"')
    end
    allow(Muni::Www::Auth).to receive(:mode).and_return('pilot')
    get '/'
    expect(last_response.body).not_to include('href="/signup"')
  end

  it 'does not create a local account when live verification fails' do
    allow(provider).to receive(:verify_user).and_raise(Muni::Www::Auth::Error)
    sign_in
    expect(last_response.status).to eq(400)
    expect(Muni::Store.db[:accounts].count).to eq(0)
    expect(Muni::Store.db[:account_sessions].count).to eq(0)
  end

  it 'leaves password sign-in available after cancelled passkey enrollment' do
    sign_in
    submit '/account/passkeys'
    state = URI.decode_www_form(URI(last_response.location).query).to_h.fetch('state')
    get 'https://muni.example/auth/cognito/callback', state: state, error: 'access_denied'
    expect(last_response.status).to eq(400)
    sign_in
    expect(last_response.status).to eq(302)
    expect(Muni::Store.db[:accounts].count).to eq(1)
  end

  it 'serializes simultaneous refreshes while allowing unrelated database writes' do
    row = sign_in
    token = rack_mock_session.cookie_jar['__Host-muni_session']
    Muni::Store.db[:account_sessions].update(token_expires_at: Time.now.to_i - 1)
    started = Queue.new
    release = Queue.new
    allow(provider).to receive(:refresh) {
      started << true
      release.pop
      tokens.merge('refresh_token' => 'rotated')
    }
    first = Thread.new { service.session(token) }
    started.pop
    expect { service.session(token) }.to raise_error(Muni::Www::Auth::Unavailable)
    Muni::Accounts.preference(row[:account_id], 'boston')
    release << true
    expect(first.value[:plaintext_tokens]['refresh_token']).to eq('rotated')
    expect(provider).to have_received(:refresh).once
  ensure
    release << true if release
    first&.join(5)
  end

  it 'removes the local session when the refresh token has been revoked' do
    sign_in
    token = rack_mock_session.cookie_jar['__Host-muni_session']
    Muni::Store.db[:account_sessions].update(token_expires_at: Time.now.to_i - 1)
    allow(provider).to receive(:refresh).and_raise(Muni::Www::Auth::Error)
    expect(service.session(token)).to be_nil
    expect(Muni::Accounts.session(token)).to be_nil
  end

  it 'invalidates both local sessions on sign out everywhere' do
    first = sign_in
    clear_cookies
    sign_in
    expect(Muni::Store.db[:account_sessions].count).to eq(2)
    submit '/logout-all'
    expect(last_response.status).to eq(303)
    expect(Muni::Store.db[:account_sessions].where(account_id: first[:account_id]).count).to eq(0)
    expect(provider).to have_received(:global_sign_out).with(tokens)
  end

  it 'finishes a previously failed deletion without restoring access or touching municipal tables' do
    row = sign_in
    Muni::Accounts.deletion_pending(row[:account_id])
    before = Muni::Store.counts_by_source
    Muni::Accounts.deletion_complete(row[:account_id])
    expect(Muni::Accounts.resolve(claims)).to be_nil
    expect(Muni::Store.counts_by_source).to eq(before)
    Muni::Accounts.start_transaction('cleanup', 'browser', 'ciphertext', now: Time.now.to_i + 604_801)
    expect(Muni::Accounts.account(row[:account_id])).to be_nil
  end
end
