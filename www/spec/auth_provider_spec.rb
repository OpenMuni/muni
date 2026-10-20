require 'spec_helper'

RSpec.describe Muni::Www::Auth::Provider do
  let(:config) do
    Muni::Www::Auth::Config.new(
      'MUNI_PUBLIC_BASE_URL' => 'https://muni.example', 'MUNI_COGNITO_DOMAIN' => 'https://auth.muni.example',
      'MUNI_COGNITO_POOL_ID' => 'us-east-1_example', 'MUNI_COGNITO_CLIENT_ID' => 'client',
      'MUNI_COGNITO_CLIENT_SECRET' => 'fixture-only', 'MUNI_AUTH_ENCRYPTION_KEY' => Base64.strict_encode64('k' * 32)
    )
  end
  let(:key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:jwk) { JWT::JWK.new(key, 'test-key') }
  let(:provider) { described_class.new(config) }
  let(:claims) do
    { 'iss' => config.issuer, 'sub' => 'subject', 'auth_time' => Time.now.to_i,
      'iat' => Time.now.to_i, 'exp' => Time.now.to_i + 300 }
  end

  before do
    stub_request(:get, "#{config.issuer}/.well-known/jwks.json")
      .to_return(status: 200, body: JSON.generate(keys: [jwk.export]))
  end

  def signed(claims)
    JWT.encode(claims, key, 'RS256', kid: 'test-key')
  end

  def tokens(id_changes = {}, access_changes = {})
    id = claims.merge('aud' => 'client', 'token_use' => 'id', 'email' => 'user@example.test',
                      'email_verified' => true, 'nonce' => 'nonce').merge(id_changes)
    access = claims.merge('client_id' => 'client', 'token_use' => 'access',
                          'scope' => 'openid email aws.cognito.signin.user.admin').merge(access_changes)
    { 'id_token' => signed(id), 'access_token' => signed(access) }
  end

  it 'accepts correctly signed, paired tokens and the expected nonce' do
    expect(provider.validate(tokens, nonce: 'nonce')['sub']).to eq('subject')
  end

  it 'rejects the wrong issuer, audience, token purpose, expiry, and unverified email' do
    [{ 'iss' => 'https://attacker.example' }, { 'aud' => 'other-client' }, { 'token_use' => 'access' },
     { 'exp' => Time.now.to_i - 1 }, { 'email_verified' => false }].each do |changes|
      expect { provider.validate(tokens(changes), nonce: 'nonce') }.to raise_error(Muni::Www::Auth::Error)
    end
  end

  it 'rejects the wrong nonce, access client, access scope, and cross-account tokens' do
    expect { provider.validate(tokens, nonce: 'wrong') }.to raise_error(Muni::Www::Auth::Error)
    [{ 'client_id' => 'other' }, { 'sub' => 'other' }, { 'scope' => 'openid' }].each do |changes|
      expect { provider.validate(tokens({}, changes)) }.to raise_error(Muni::Www::Auth::Error)
    end
  end

  it 'rejects unsigned and forged signatures' do
    data = tokens
    data['id_token'] = JWT.encode(claims, nil, 'none')
    expect { provider.validate(data) }.to raise_error(Muni::Www::Auth::Error)
    data['id_token'] = JWT.encode(claims, OpenSSL::PKey::RSA.generate(2048), 'RS256', kid: 'test-key')
    expect { provider.validate(data) }.to raise_error(Muni::Www::Auth::Error)
  end

  it 'uses S256 PKCE, a fixed redirect, explicit scopes, and fresh authentication' do
    transaction = { 'nonce' => 'nonce', 'verifier' => 'verifier', 'purpose' => 'login' }
    url = URI(provider.authorize(transaction, 'state'))
    query = URI.decode_www_form(url.query).to_h
    expect(query).to include('response_type' => 'code', 'code_challenge_method' => 'S256', 'prompt' => 'login',
                             'redirect_uri' => config.callback, 'state' => 'state', 'nonce' => 'nonce')
    expect(query['code_challenge']).to eq(Base64.urlsafe_encode64(Digest::SHA256.digest('verifier'), padding: false))
    expect(query).not_to have_key('client_secret')
  end

  it 'authenticates ciphertext and rejects a changed encrypted token' do
    vault = Muni::Www::Auth::Vault.new(config.key)
    encrypted = vault.seal(tokens)
    expect(vault.open(encrypted)).to eq(tokens)
    parts = encrypted.split('.')
    parts[1] = Base64.strict_encode64('x' * 16)
    expect { vault.open(parts.join('.')) }.to raise_error(Muni::Www::Auth::Error)
  end

  it 'uses a separate fixed return URL for hosted passkey enrollment, without requesting OAuth tokens' do
    url = URI(provider.enrollment_url)
    expect("#{url.scheme}://#{url.host}#{url.path}").to eq('https://auth.muni.example/passkeys/add')
    expect(URI.decode_www_form(url.query).to_h).to eq(
      'client_id' => 'client', 'redirect_uri' => 'https://muni.example/auth/passkeys/complete'
    )
  end

  it 'exchanges a code with the verifier and confidential client authentication' do
    response = tokens.merge('refresh_token' => 'first-refresh', 'expires_in' => 300, 'token_type' => 'Bearer')
    request = stub_request(:post, 'https://auth.muni.example/oauth2/token')
              .with(basic_auth: %w[client fixture-only], body: hash_including(
                'grant_type' => 'authorization_code', 'code' => 'code', 'code_verifier' => 'verifier',
                'redirect_uri' => config.callback
              )).to_return(status: 200, body: JSON.generate(response),
                           headers: { 'Content-Type' => 'application/json' })
    expect(provider.exchange('code', 'verifier')).to include(response.except('token_type', 'expires_in'))
    expect(request).to have_been_requested.once
  end

  it 'retains the rotated refresh token and receives a replacement ID token' do
    response = tokens.merge('refresh_token' => 'rotated-refresh', 'expires_in' => 300, 'token_type' => 'Bearer')
    stub_request(:post, 'https://auth.muni.example/oauth2/token')
      .with(basic_auth: %w[client fixture-only], body: hash_including(
        'grant_type' => 'refresh_token', 'refresh_token' => 'old-refresh'
      )).to_return(status: 200, body: JSON.generate(response), headers: { 'Content-Type' => 'application/json' })
    expect(provider.refresh(tokens.merge('refresh_token' => 'old-refresh')))
      .to include('refresh_token' => 'rotated-refresh', 'id_token' => response['id_token'])
  end

  it 'distinguishes revoked refresh tokens from a temporary provider failure without exposing tokens' do
    stub_request(:post, 'https://auth.muni.example/oauth2/token')
      .to_return(status: 400, body: '{"error":"invalid_grant","description":"sensitive-provider-detail"}',
                 headers: { 'Content-Type' => 'application/json' })
    expect { provider.refresh(tokens.merge('refresh_token' => 'old-refresh')) }
      .to raise_error(Muni::Www::Auth::Error, 'Please sign in again')
    stub_request(:post, 'https://auth.muni.example/oauth2/token').to_timeout
    expect { provider.exchange('secret-code', 'verifier') }
      .to raise_error(Muni::Www::Auth::Unavailable, 'Account service temporarily unavailable')
  end

  it 'refreshes trusted signing keys after a rotation without following token-supplied URLs' do
    provider.validate(tokens)
    replacement = JWT::JWK.new(OpenSSL::PKey::RSA.generate(2048), 'rotated-key')
    provider.instance_variable_set(:@keys_at, Process.clock_gettime(Process::CLOCK_MONOTONIC) - 61)
    stub_request(:get, "#{config.issuer}/.well-known/jwks.json")
      .to_return(status: 200, body: JSON.generate(keys: [jwk.export, replacement.export]))
    rotated = tokens
    id = JWT.decode(rotated['id_token'], nil, false).first
    rotated['id_token'] = JWT.encode(id, replacement.signing_key, 'RS256', kid: 'rotated-key',
                                                                           jku: 'https://attacker.example/keys')
    expect(provider.validate(rotated)['sub']).to eq('subject')
    expect(a_request(:get, 'https://attacker.example/keys')).not_to have_been_made
  end

  it 'uses user access tokens for account operations without AWS service credentials' do
    response = { Username: 'subject', UserAttributes: [
      { Name: 'sub', Value: 'subject' }, { Name: 'email_verified', Value: 'true' }
    ] }
    request = stub_request(:post, 'https://cognito-idp.us-east-1.amazonaws.com/')
              .with(headers: { 'X-Amz-Target' => 'AWSCognitoIdentityProviderService.GetUser' },
                    body:    JSON.generate(AccessToken: 'user-access'))
              .to_return(status: 200, body: JSON.generate(response),
                         headers: { 'Content-Type' => 'application/x-amz-json-1.1' })
    provider.verify_user({ 'access_token' => 'user-access' }, 'subject')
    expect(request).to have_been_requested.once
  end
end
