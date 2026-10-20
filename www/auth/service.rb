require_relative 'config'
require_relative 'vault'
require_relative 'provider'

module Muni
  module Www
    module Auth
      class Service
        attr_reader :config, :provider, :vault

        def initialize(config, provider: Provider.new(config))
          @config = config
          @provider = provider
          @vault = Vault.new(config.key)
        end

        def begin_flow(purpose:, browser:, account: nil, path: '/oauth2/authorize')
          state = SecureRandom.urlsafe_base64(32)
          transaction = { 'purpose' => purpose, 'nonce' => SecureRandom.urlsafe_base64(32),
                          'verifier' => SecureRandom.urlsafe_base64(48), 'account_id' => account&.fetch(:id),
                          'subject' => account&.fetch(:subject) }
          Accounts.start_transaction(state, browser, vault.seal(transaction))
          provider.authorize(transaction, state, path: path)
        end

        def callback(state:, browser:, code:, previous: nil)
          payload = Accounts.consume_transaction(state, browser)
          raise Error, 'This sign-in link expired. Please try again.' unless payload && !code.to_s.empty?

          transaction = vault.open(payload)
          tokens = provider.exchange(code, transaction.fetch('verifier'))
          claims = provider.validate(tokens, nonce: transaction.fetch('nonce'))
          account = callback_account(transaction, tokens, claims)
          if transaction['purpose'] == 'recover'
            Accounts.revoke_all(account[:id])
            provider.global_sign_out(tokens)
            return { recovery: true }
          end
          provider.credentials(tokens) if transaction['purpose'] == 'enroll'
          sid = Accounts.create_session(account[:id], vault.seal(tokens), claims, previous: previous)
          raise Error, 'Session was revoked during sign-in' unless sid

          { sid: sid, purpose: transaction['purpose'] }
        end

        def callback_account(transaction, tokens, claims)
          if transaction['subject'] && transaction['subject'] != claims['sub']
            raise Error, 'Sign in with the same account to continue'
          end
          if transaction['purpose'] != 'enroll' && claims['auth_time'] < Time.now.to_i - 300
            raise Error, 'Please sign in again to continue'
          end

          provider.verify_user(tokens, claims.fetch('sub'))
          account = Accounts.resolve(claims)
          raise Error, 'Account unavailable. Please sign in again.' unless account
          if transaction['account_id'] && transaction['account_id'] != account[:id]
            raise Error, 'Account changed during sign-in'
          end

          account
        end

        def session(sid)
          row = Accounts.session(sid)
          return nil unless row

          row = refresh_session(sid) if row[:token_expires_at] <= Time.now.to_i + 15
          tokens = vault.open(row.fetch(:tokens))
          claims = provider.validate(tokens)
          raise Error, 'Session account changed' unless claims['sub'] == row[:account][:subject]

          Accounts.touch(sid) if row[:idle_until] < Time.now.to_i + Accounts::IDLE_SECONDS - 60
          row.merge(plaintext_tokens: tokens)
        rescue Error => e
          raise if e.is_a?(Unavailable)

          Accounts.remove_session(sid)
          nil
        end

        def refresh_session(sid)
          owner = SecureRandom.uuid
          unless Accounts.claim_refresh(sid, owner)
            raise Unavailable, 'Another request is refreshing this session. Please try again.'
          end

          # Re-read after obtaining the lease: a concurrent request might already have refreshed it.
          row = Accounts.session(sid)
          raise Error, 'Session expired' unless row

          tokens = vault.open(row[:tokens])
          if row[:token_expires_at] <= Time.now.to_i + 15
            tokens = provider.refresh(tokens)
            claims = provider.validate(tokens)
            raise Error, 'Session account changed' unless claims['sub'] == row[:account][:subject]

            provider.verify_user(tokens, claims.fetch('sub'))
            row[:token_expires_at] = claims.fetch('exp')
          end
          saved = Accounts.finish_refresh(sid, owner, vault.seal(tokens), row[:token_expires_at])
          raise Error, 'Session was revoked' unless saved

          Accounts.session(sid) || raise(Error, 'Session was revoked')
        end
      end
    end
  end
end
