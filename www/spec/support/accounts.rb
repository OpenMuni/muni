require 'spec_helper'
require 'uri'

RSpec.shared_context 'with Cognito accounts' do
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
end
