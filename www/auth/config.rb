require 'uri'
require 'base64'

module Muni
  module Www
    module Auth
      class Error < StandardError; end
      class Unavailable < Error; end

      def self.mode = ENV.fetch('MUNI_AUTH_MODE', 'off')
      def self.passkeys_enabled? = ENV.fetch('MUNI_AUTH_PASSKEYS_ENABLED', '0') == '1'
      def self.service = @service ||= Service.new(Config.new)

      class Config
        attr_reader :base_url, :domain, :client_id, :client_secret, :region, :pool_id, :key

        def initialize(env = ENV)
          @base_url = origin(env.fetch('MUNI_PUBLIC_BASE_URL'))
          @domain = origin(env.fetch('MUNI_COGNITO_DOMAIN'))
          @client_id = env.fetch('MUNI_COGNITO_CLIENT_ID')
          @client_secret = env.fetch('MUNI_COGNITO_CLIENT_SECRET')
          @pool_id = env.fetch('MUNI_COGNITO_POOL_ID')
          raise Error, 'Invalid pool ID' unless @pool_id.match?(/\A[a-z]{2}-[a-z]+-\d_[a-zA-Z0-9]+\z/)

          @region = @pool_id.split('_').first
          @key = Base64.strict_decode64(env.fetch('MUNI_AUTH_ENCRYPTION_KEY'))
          raise Error, 'Invalid encryption key' unless @key.bytesize == 32
          raise Error, 'Missing client credentials' if @client_id.empty? || @client_secret.empty?
        rescue KeyError, ArgumentError, URI::InvalidURIError
          raise Error, 'Incomplete authentication configuration'
        end

        def issuer = "https://cognito-idp.#{region}.amazonaws.com/#{pool_id}"
        def callback = "#{base_url}/auth/cognito/callback"
        def enrollment_return = "#{base_url}/auth/passkeys/complete"
        def signed_out = "#{base_url}/auth/signed-out"

        private

        def origin(value)
          uri = URI(value)
          unless uri.scheme == 'https' && uri.host && !uri.userinfo && !uri.query && !uri.fragment &&
                 ['', '/'].include?(uri.path) && uri.port == 443
            raise Error, 'Authentication requires an HTTPS origin'
          end

          "https://#{uri.host}"
        end
      end
    end
  end
end
