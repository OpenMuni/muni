require_relative 'support/accounts'

RSpec.describe 'Account profile names' do
  include_context 'with Cognito accounts'

  it 'offers the name form immediately after the first verified sign-in' do
    sign_in
    follow_redirect!
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('Complete your profile', 'action="/account/profile"',
                                          'autocomplete="given-name"', 'autocomplete="family-name"',
                                          'Continue browsing public information')
    expect(provider).to have_received(:verify_user).with(tokens, claims['sub'])
    expect(last_response.headers['cache-control']).to eq('no-store, private')
  end

  it 'offers the same form to existing nameless accounts without blocking account controls' do
    account = Muni::Accounts.resolve(claims, now: Time.now.to_i - 86_400)
    sign_in
    follow_redirect!
    expect(last_response.body).to include('Complete your profile', 'action="/account/preference"',
                                          'action="/account/delete"', 'Add a passkey')
    expect(Muni::Store.db[:accounts].select_map(:id)).to eq([account[:id]])
    submit '/account/preference', hall: 'boston'
    expect(last_response.status).to eq(303)
  end

  it 'saves trimmed Unicode names and allows editing them on the account page' do
    row = sign_in
    submit '/account/profile', first_name: " \u3000Élodie\u00a0 ", last_name: ' 李 '
    expect(last_response.status).to eq(303)
    follow_redirect!
    expect(last_response.body).to include('Your account', 'value="Élodie"', 'value="李"')
    expect(last_response.body).not_to include('Complete your profile')
    submit '/account/profile', first_name: 'Zoë', last_name: 'O’Connor'
    expect(Muni::Accounts.account(row[:account_id])).to include(first_name: 'Zoë', last_name: 'O’Connor',
                                                                issuer: claims['iss'], subject: claims['sub'])
    sign_in
    follow_redirect!
    expect(last_response.body).to include('value="Zoë"', 'value="O’Connor"')
  end

  it 'escapes names in input attributes, navigation text and accessible labels' do
    sign_in
    name = '"><script>alert(1)</script>'
    submit '/account/profile', first_name: name, last_name: "O'Connor & 李"
    follow_redirect!
    expect(last_response.body).to include("value=\"#{Rack::Utils.escape_html(name)}\"")
    allow(Muni::Www::Auth).to receive(:mode).and_return('public')
    get 'https://muni.example/about'
    expect(last_response.body).to include("<bdi>#{Rack::Utils.escape_html(name)}</bdi>",
                                          "aria-label=\"#{Rack::Utils.escape_html("#{name} — Account")}\"")
    expect(last_response.body).not_to include(name)
  end

  ['', " \u3000 ", 'a' * 101, "line\nbreak", ['array'], { 'nested' => 'value' }, nil].each do |invalid|
    it "rejects invalid submitted names (#{invalid.inspect}) without a partial update" do
      row = sign_in
      submit '/account/profile', first_name: 'Original', last_name: 'Name'
      submit '/account/profile', first_name: 'Replacement', last_name: invalid
      expect(last_response.status).to eq(422)
      expect(last_response.body).to include('role="alert"', 'value="Replacement"')
      expect(Muni::Accounts.account(row[:account_id])).to include(first_name: 'Original', last_name: 'Name')
    end
  end

  it 'escapes rejected input when redisplaying the form' do
    sign_in
    submit '/account/profile', first_name: '"><img src=x onerror=alert(1)>', last_name: ''
    expect(last_response.status).to eq(422)
    expect(last_response.body).to include('&quot;&gt;&lt;img')
    expect(last_response.body).not_to include('<img src=x')
  end

  it 'accepts the 100-character Unicode limit without treating bytes as characters' do
    row = sign_in
    submit '/account/profile', first_name: '李' * 100, last_name: 'É' * 100
    expect(last_response.status).to eq(303)
    expect(Muni::Accounts.account(row[:account_id])[:first_name]).to eq('李' * 100)
  end

  it 'requires the current session CSRF token' do
    row = sign_in
    [nil, '', 'forged'].each do |csrf|
      submit '/account/profile', first_name: 'Changed', last_name: 'Name', csrf: csrf
      expect(last_response.status).to eq(403)
    end
    expect(Muni::Accounts.account(row[:account_id])).to include(first_name: nil, last_name: nil)
  end

  it 'rejects foreign or missing origins even with the correct token' do
    row = sign_in
    [nil, 'https://attacker.example', 'null'].each do |origin|
      post 'https://muni.example/account/profile', { csrf: row[:csrf], first_name: 'Changed', last_name: 'Name' },
           'HTTP_ORIGIN' => origin
      expect(last_response.status).to eq(403)
    end
    expect(Muni::Accounts.account(row[:account_id])[:first_name]).to be_nil
  end

  it 'accepts same-origin privacy-preserving form submissions' do
    row = sign_in
    post 'https://muni.example/account/profile', { csrf: row[:csrf], first_name: 'Ada', last_name: 'Lovelace' },
         'HTTP_ORIGIN' => 'null', 'HTTP_SEC_FETCH_SITE' => 'same-origin'
    expect(last_response.status).to eq(303)
    expect(Muni::Accounts.account(row[:account_id])[:first_name]).to eq('Ada')
  end

  it 'updates only the session owner regardless of submitted account identifiers' do
    first = sign_in
    submit '/account/profile', first_name: 'First', last_name: 'Resident'
    clear_cookies
    allow(provider).to receive(:validate).and_return(claims.merge('sub' => 'second-subject'))
    second = sign_in
    submit '/account/profile', first_name: 'Second', last_name: 'Resident',
                               account_id: first[:account_id], id: first[:account_id], subject: claims['sub']
    expect(last_response.status).to eq(303)
    expect(Muni::Accounts.account(first[:account_id])[:first_name]).to eq('First')
    expect(Muni::Accounts.account(second[:account_id])[:first_name]).to eq('Second')
    submit '/account/profile', first_name: 'Forged', last_name: 'Name', csrf: first[:csrf]
    expect(last_response.status).to eq(403)
  end

  it 'does not update a profile without a live authenticated session' do
    row = sign_in
    Muni::Accounts.revoke_all(row[:account_id])
    post 'https://muni.example/account/profile', { csrf: row[:csrf], first_name: 'Changed', last_name: 'Name' },
         'HTTP_ORIGIN' => 'https://muni.example'
    expect(last_response.location).to end_with('/login')
    expect(Muni::Accounts.account(row[:account_id])[:first_name]).to be_nil
  end
end
