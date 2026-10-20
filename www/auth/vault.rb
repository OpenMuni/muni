require 'openssl'
require 'base64'
require 'json'

module Muni
  module Www
    module Auth
      class Vault
        def initialize(key)
          @key = key
        end

        def seal(value)
          cipher = OpenSSL::Cipher.new('aes-256-gcm').encrypt
          cipher.key = @key
          iv = cipher.random_iv
          cipher.auth_data = 'muni-accounts-v1'
          encrypted = cipher.update(JSON.generate(value)) + cipher.final
          [iv, cipher.auth_tag, encrypted].map { |part| Base64.strict_encode64(part) }.join('.')
        end

        def open(value)
          iv, tag, encrypted = value.split('.').map { |part| Base64.strict_decode64(part) }
          raise Error, 'Invalid encrypted value' unless iv&.bytesize == 12 && tag&.bytesize == 16 && encrypted

          cipher = OpenSSL::Cipher.new('aes-256-gcm').decrypt
          cipher.key = @key
          cipher.iv = iv
          cipher.auth_tag = tag
          cipher.auth_data = 'muni-accounts-v1'
          JSON.parse(cipher.update(encrypted) + cipher.final)
        rescue OpenSSL::Cipher::CipherError, ArgumentError, JSON::ParserError
          raise Error, 'Invalid encrypted value'
        end
      end
    end
  end
end
