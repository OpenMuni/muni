require 'oauth2'
require 'jwt'
require 'aws-sdk-cognitoidentityprovider'

module Muni
  module Www
    module Auth
      class Provider
        SCOPES = 'openid email aws.cognito.signin.user.admin'.freeze

        def initialize(config)
          @config = config
          @jwks_mutex = Mutex.new
          @oauth = OAuth2::Client.new(config.client_id, config.client_secret, site: config.domain,
                                     authorize_url: '/oauth2/authorize', token_url: '/oauth2/token',
                                     auth_scheme: :basic_auth,
                                     connection_opts: { request: { open_timeout: 3, timeout: 8 } })
          @cognito = Aws::CognitoIdentityProvider::Client.new(region: config.region, retry_limit: 1,
                                                              http_open_timeout: 3, http_read_timeout: 8,
                                                              credentials: Aws::Credentials.new(nil, nil))
        end

        def authorize(transaction, state, path: '/oauth2/authorize')
          query = { client_id: @config.client_id, response_type: 'code', redirect_uri: @config.callback,
                    scope: SCOPES, state: state, nonce: transaction.fetch('nonce'),
                    code_challenge_method: 'S256',
                    code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(transaction.fetch('verifier')),
                                                            padding: false) }
          query[:prompt] = 'login' unless transaction['purpose'] == 'enroll'
          "#{@config.domain}#{path}?#{URI.encode_www_form(query)}"
        end

        def exchange(code, verifier)
          safely do
            token = @oauth.auth_code.get_token(code, redirect_uri: @config.callback, code_verifier: verifier)
            token.to_hash.transform_keys(&:to_s)
          end
        end

        def refresh(tokens)
          safely do
            token = OAuth2::AccessToken.from_hash(@oauth, tokens.transform_keys(&:to_sym)).refresh!
            token.to_hash.transform_keys(&:to_s)
          end
        end

        def validate(tokens, nonce: nil)
          id = decode(tokens.fetch('id_token'))
          access = decode(tokens.fetch('access_token'))
          valid = valid_identity?(id) && valid_access?(access, id)
          valid &&= id['nonce'] == nonce if nonce
          raise Error, 'Invalid authentication result' unless valid

          id.merge('exp' => [id.fetch('exp'), access.fetch('exp')].min)
        rescue JWT::DecodeError, KeyError, TypeError
          raise Error, 'Invalid authentication result'
        end

        def verify_user(tokens, subject)
          user = safely { @cognito.get_user(access_token: tokens.fetch('access_token')) }
          attributes = user.user_attributes.to_h { |attribute| [attribute.name, attribute.value] }
          raise Error, 'Invalid account' unless attributes['sub'] == subject && attributes['email_verified'] == 'true'
        end

        def credentials(tokens)
          safely do
            result = []
            next_token = nil
            loop do
              page = @cognito.list_web_authn_credentials(access_token: tokens.fetch('access_token'),
                                                         next_token:   next_token)
              result.concat(page.credentials.map(&:to_h))
              next_token = page.next_token
              break unless next_token
            end
            result
          end
        end

        def remove_credential(tokens, id)
          safely { @cognito.delete_web_authn_credential(access_token: tokens.fetch('access_token'), credential_id: id) }
        end

        def delete_user(tokens)
          safely { @cognito.delete_user(access_token: tokens.fetch('access_token')) }
        end

        def global_sign_out(tokens)
          safely { @cognito.global_sign_out(access_token: tokens.fetch('access_token')) }
        end

        def revoke(tokens)
          safely do
            @cognito.revoke_token(token: tokens.fetch('refresh_token'), client_id: @config.client_id,
                                  client_secret: @config.client_secret)
          end
        end

        def logout_url
          "#{@config.domain}/logout?#{URI.encode_www_form(client_id:  @config.client_id,
                                                          logout_uri: @config.signed_out)}"
        end

        private

        def valid_identity?(id)
          id['token_use'] == 'id' && id['aud'] == @config.client_id && !id['sub'].to_s.empty? &&
            id['email_verified'] == true && !id['email'].to_s.empty? && id['auth_time'].is_a?(Integer) &&
            id['auth_time'] <= Time.now.to_i + 30
        end

        def valid_access?(access, id)
          access['token_use'] == 'access' && access['client_id'] == @config.client_id &&
            access['sub'] == id['sub'] && access['scope'].to_s.split.include?('aws.cognito.signin.user.admin')
        end

        def decode(token)
          JWT.decode(token, nil, true, algorithms: ['RS256'], jwks: method(:jwks),
                     iss: @config.issuer, verify_iss: true, verify_iat: true,
                     required_claims: %w[exp iat iss sub token_use auth_time]).first
        end

        def jwks(options = {})
          @jwks_mutex.synchronize do
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            refresh = !@keys || now - @keys_at > 3600 || (options[:kid_not_found] && now - @keys_at > 60)
            if refresh
              response = Faraday.get("#{@config.issuer}/.well-known/jwks.json") do |request|
                request.options.timeout = 5
                request.options.open_timeout = 3
              end
              raise Unavailable, 'Signing keys unavailable' unless response.success? && response.body.bytesize < 131_072

              @keys = JSON.parse(response.body)
              @keys_at = now
            end
            @keys
          end
        rescue Faraday::Error, JSON::ParserError
          raise Unavailable, 'Signing keys unavailable'
        end

        def safely
          yield
        rescue Aws::CognitoIdentityProvider::Errors::NotAuthorizedException
          raise Error, 'Please sign in again'
        rescue OAuth2::Error => e
          parsed = e.response.parsed
          if parsed.is_a?(Hash) && %w[invalid_grant invalid_token].include?(parsed['error'])
            raise Error, 'Please sign in again'
          end

          raise Unavailable, 'Account service temporarily unavailable'
        rescue Faraday::Error, Seahorse::Client::NetworkingError,
               Aws::CognitoIdentityProvider::Errors::ServiceError
          # Provider exceptions can contain tokens, authorization codes, and personal data.
          raise Unavailable, 'Account service temporarily unavailable'
        end
      end
    end
  end
end
