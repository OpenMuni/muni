require_relative 'support/accounts'

RSpec.describe 'Account city and home station preferences' do
  include_context 'with Cognito accounts'

  def save_station(hall: 'cambridge', line: 'Red', station: 'place-harsq', **attributes)
    submit '/account/preference', { hall: hall, home_station_line: line, home_station_id: station }.merge(attributes)
  end

  %w[boston cambridge].each do |hall|
    it "saves #{hall} with browser privacy headers and restores the city on reload" do
      row = sign_in
      follow_redirect!
      expect(last_response.headers['referrer-policy']).to eq('no-referrer')
      post 'https://muni.example/account/preference', { hall: hall, csrf: row[:csrf] },
           'HTTP_ORIGIN' => 'null', 'HTTP_SEC_FETCH_SITE' => 'same-origin'
      expect(last_response.status).to eq(303)
      expect(Array(last_response.headers['set-cookie']).join).to include("hall=#{hall}", 'secure', 'samesite=lax')
      follow_redirect!
      expect(last_response.body).to include('role="status"', 'preferences have been saved.')
      get 'https://muni.example/account'
      expect(last_response.body).to match(/value="#{hall}"[^>]*selected/)
      expect(Muni::Accounts.account(row[:account_id])).to include(preferred_hall: hall, home_station_id: nil)
    end
  end

  it 'restores the saved line and canonical station across visits and a new sign-in' do
    row = sign_in
    save_station
    expect(last_response.status).to eq(303)
    sign_in
    follow_redirect!
    expect(last_response.body).to include('value="Red" selected')
    expect(last_response.body).to match(/value="place-harsq"[^>]*selected/)
    expect(Muni::Accounts.account(row[:account_id])).to include(
      preferred_hall: 'cambridge', home_station_network: 'mbta',
      home_station_line: 'Red', home_station_id: 'place-harsq'
    )
  end

  it 'preserves the home station when switching cities, including city-only clients' do
    row = sign_in
    save_station
    save_station(hall: 'boston')
    expect(last_response.status).to eq(303)
    submit '/account/preference', hall: 'cambridge'
    expect(Muni::Accounts.account(row[:account_id])).to include(
      preferred_hall: 'cambridge', home_station_id: 'place-harsq', home_station_line: 'Red'
    )
  end

  %w[Red Green-B Green-C Green-D Green-E].each do |line|
    it "accepts the Park Street parent station on #{line}" do
      row = sign_in
      save_station(line: line, station: 'place-pktrm')
      expect(last_response.status).to eq(303)
      expect(Muni::Accounts.account(row[:account_id])).to include(home_station_id:   'place-pktrm',
                                                                  home_station_line: line)
    end
  end

  it 'changes and clears a station without requiring one to save a city' do
    row = sign_in
    save_station
    save_station(line: 'Blue', station: 'place-gover')
    expect(Muni::Accounts.account(row[:account_id])[:home_station_id]).to eq('place-gover')
    save_station(line: 'Blue', station: '')
    expect(Muni::Accounts.account(row[:account_id])).to include(home_station_line: 'Blue', home_station_id: nil)
    save_station
    save_station(hall: 'boston', line: '', station: '')
    expect(last_response.status).to eq(303)
    expect(Muni::Accounts.account(row[:account_id])).to include(
      Muni::Accounts::Preferences::EMPTY.merge(preferred_hall: 'boston')
    )
  end

  [
    { hall: 'unknown' }, { hall: '' }, { hall: ['boston'] }, { hall: { 'slug' => 'boston' } },
    { line: 'CR-Fitchburg' }, { line: 'Green' }, { line: ['Red'] }, { line: nil },
    { station: ['place-harsq'] }, { station: { 'id' => 'place-harsq' } }, { station: nil },
    { line: 'Blue' }, { line: '' }, { station: '70068' }, { station: 'place-fake' }
  ].each do |invalid|
    it "rejects invalid combinations atomically: #{invalid.inspect}" do
      row = sign_in
      save_station
      before = Muni::Accounts.account(row[:account_id])
      save_station(**invalid)
      expect(last_response.status).to eq(422)
      expect(last_response.body).to include('role="alert"', 'action="/account/preference"')
      expect(Muni::Accounts.account(row[:account_id])).to eq(before)
      expect(last_response.headers['set-cookie']).to be_nil
    end
  end

  it 'rejects a configured but nonpublic city' do
    row = sign_in
    allow(Muni::Hall.find('boston')).to receive(:public?).and_return(false)
    save_station(hall: 'boston')
    expect(last_response.status).to eq(422)
    expect(Muni::Accounts.account(row[:account_id])[:preferred_hall]).to be_nil
  end

  it 'escapes station names and submitted values on validation errors' do
    stations.first['name'] = '<script>untrusted</script>'
    sign_in
    save_station(line: '"><script>alert(1)</script>')
    expect(last_response.status).to eq(422)
    expect(last_response.body).to include('&lt;script&gt;untrusted&lt;/script&gt;')
    expect(last_response.body).not_to include('<script>untrusted', '<script>alert')
  end

  it 'keeps city saving and explicit clearing available during an MBTA outage' do
    row = sign_in
    save_station
    allow(Muni::Transit).to receive(:stations).and_raise(Muni::Transit::Client::Error, 'unavailable')
    get 'https://muni.example/account'
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('temporarily unavailable', 'Save city', 'place-harsq')
    expect(last_response.body).not_to include('name="home_station_id"')
    submit '/account/preference', hall: 'boston'
    expect(last_response.status).to eq(303)
    expect(Muni::Accounts.account(row[:account_id])).to include(preferred_hall:  'boston',
                                                                home_station_id: 'place-harsq')
    submit '/account/preference', hall: 'boston', clear_station: '1'
    expect(last_response.status).to eq(303)
    expect(Muni::Accounts.account(row[:account_id])).to include(Muni::Accounts::Preferences::EMPTY)
  end

  it 'does not accept an unverified station if MBTA fails between displaying and submitting the form' do
    row = sign_in
    allow(Muni::Transit).to receive(:stations).and_raise(Muni::Transit::Client::Error, 'unavailable')
    save_station
    expect(last_response.status).to eq(503)
    expect(last_response.body).to include('save just your city', 'Save city')
    expect(Muni::Accounts.account(row[:account_id])).to include(preferred_hall: nil, home_station_id: nil)
  end

  it 'requires the current CSRF token for changing or clearing preferences' do
    row = sign_in
    save_station
    [nil, '', 'forged'].each do |csrf|
      save_station(station: 'place-pktrm', csrf: csrf)
      expect(last_response.status).to eq(403)
      submit '/account/preference', hall: 'boston', clear_station: '1', csrf: csrf
      expect(last_response.status).to eq(403)
    end
    expect(Muni::Accounts.account(row[:account_id])).to include(preferred_hall:  'cambridge',
                                                                home_station_id: 'place-harsq')
  end

  it 'rejects missing, opaque and foreign origins without same-origin browser evidence' do
    row = sign_in
    [nil, 'null', 'https://attacker.example'].each do |origin|
      post 'https://muni.example/account/preference',
           { hall: 'boston', csrf: row[:csrf], home_station_line: 'Red', home_station_id: 'place-harsq' },
           'HTTP_ORIGIN' => origin, 'HTTP_SEC_FETCH_SITE' => 'cross-site'
      expect(last_response.status).to eq(403)
    end
    expect(Muni::Accounts.account(row[:account_id])[:preferred_hall]).to be_nil
  end

  it 'uses only the authenticated account, even when emails match and other IDs are submitted' do
    first = sign_in
    save_station
    clear_cookies
    allow(provider).to receive(:validate).and_return(claims.merge('sub' => 'second-subject'))
    second = sign_in
    save_station(hall: 'boston', line: 'Blue', station: 'place-gover', account_id: first[:account_id],
                 subject: claims['sub'])
    expect(last_response.status).to eq(303)
    expect(Muni::Accounts.account(first[:account_id])).to include(preferred_hall:  'cambridge',
                                                                  home_station_id: 'place-harsq')
    expect(Muni::Accounts.account(second[:account_id])).to include(preferred_hall:  'boston',
                                                                   home_station_id: 'place-gover')
    save_station(clear_station: '1', csrf: first[:csrf])
    expect(last_response.status).to eq(403)
  end

  it 'does not accept preferences without a live server-side session' do
    row = sign_in
    Muni::Accounts.revoke_all(row[:account_id])
    save_station
    expect(last_response.location).to end_with('/login')
    expect(Muni::Accounts.account(row[:account_id])[:home_station_id]).to be_nil
  end

  it 'removes city and station preferences before attempting Cognito deletion' do
    row = sign_in
    save_station
    allow(provider).to receive(:delete_user) do
      expect(Muni::Accounts.account(row[:account_id])).to include(
        Muni::Accounts::Preferences::EMPTY.merge(preferred_hall: nil, status: 'deletion_pending')
      )
    end
    submit '/account/delete', confirm: 'delete'
    expect(last_response.status).to eq(303)
    expect(Muni::Accounts.account(row[:account_id])[:status]).to eq('deleted')
    expect(Muni::Store.db[:account_sessions].count).to eq(0)
  end
end
