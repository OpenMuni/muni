require 'securerandom'
require 'digest'

module Muni
  # Account records are separate from municipal records and legacy identity data.
  module Accounts
    IDLE_SECONDS = 86_400
    MAX_SECONDS = 604_800

    class << self
      def ensure_schema!
        db.create_table?(:accounts) do
          String :id, primary_key: true
          String :issuer, null: false
          String :subject, null: false
          String :email
          String :preferred_hall
          String :status, null: false, default: 'active'
          Integer :revoked_before, null: false, default: 0
          Integer :created_at, null: false
          Integer :deleted_at
          index %i[issuer subject], unique: true
        end
        db.create_table?(:account_sessions) do
          String :id_hash, primary_key: true
          String :account_id, null: false, index: true
          String :tokens, text: true, null: false
          String :csrf, null: false
          Integer :auth_time, null: false
          Integer :expires_at, null: false
          Integer :idle_until, null: false
          Integer :token_expires_at, null: false
          String :refresh_owner
          Integer :refresh_until, null: false, default: 0
        end
        db.create_table?(:account_auth_transactions) do
          String :state_hash, primary_key: true
          String :browser_hash, null: false
          String :payload, text: true, null: false
          Integer :expires_at, null: false, index: true
        end
      end

      def db = Store.db
      def digest(value) = Digest::SHA256.hexdigest(value.to_s)

      def write(&block)
        Store.with_writer { db.transaction(&block) }
      end

      def account(id)
        db[:accounts][id: id]
      end

      def resolve(claims, now: Time.now.to_i)
        write do
          identity = { issuer: claims.fetch('iss'), subject: claims.fetch('sub') }
          row = db[:accounts][identity]
          if row
            next nil unless row[:status] == 'active' && claims.fetch('auth_time') > row[:revoked_before]

            db[:accounts].where(id: row[:id]).update(email: claims.fetch('email'))
            next account(row[:id])
          end
          id = SecureRandom.uuid
          db[:accounts].insert(identity.merge(id: id, email: claims.fetch('email'), created_at: now))
          account(id)
        end
      end

      def create_session(account_id, encrypted_tokens, claims, previous: nil, now: Time.now.to_i)
        token = SecureRandom.urlsafe_base64(32)
        write do
          row = account(account_id)
          next nil unless row && row[:status] == 'active' && claims.fetch('auth_time') > row[:revoked_before]

          db[:account_sessions].where(id_hash: digest(previous)).delete if previous
          db[:account_sessions].insert(
            id_hash: digest(token), account_id: account_id, tokens: encrypted_tokens,
            csrf: SecureRandom.urlsafe_base64(32), auth_time: claims.fetch('auth_time'),
            expires_at: now + MAX_SECONDS, idle_until: now + IDLE_SECONDS,
            token_expires_at: claims.fetch('exp')
          )
          token
        end
      end

      def session_record(token)
        return nil if token.to_s.empty?

        db[:account_sessions][id_hash: digest(token)]
      end

      def session(token, now: Time.now.to_i)
        row = session_record(token)
        return nil unless row && row[:expires_at] > now && row[:idle_until] > now

        owner = account(row[:account_id])
        return nil unless owner && owner[:status] == 'active' && row[:auth_time] > owner[:revoked_before]

        row.merge(account: owner)
      end

      def touch(token, now: Time.now.to_i)
        write { db[:account_sessions].where(id_hash: digest(token)).update(idle_until: now + IDLE_SECONDS) }
      end

      def remove_session(token)
        write { db[:account_sessions].where(id_hash: digest(token)).delete }
      end

      def revoke_all(id, now: Time.now.to_i)
        write do
          db[:accounts].where(id: id).update(revoked_before: now)
          db[:account_sessions].where(account_id: id).delete
        end
      end

      def preference(id, hall)
        write { db[:accounts].where(id: id, status: 'active').update(preferred_hall: hall) }
      end

      def deletion_pending(id)
        write do
          db[:accounts].where(id: id).update(status: 'deletion_pending', email: nil, preferred_hall: nil)
          db[:account_sessions].where(account_id: id).delete
        end
      end

      def deletion_complete(id)
        # Keep a short-lived tombstone beyond the lifetime of all outstanding tokens and transactions.
        write { db[:accounts].where(id: id).update(status: 'deleted', deleted_at: Time.now.to_i) }
      end

      def start_transaction(state, browser, payload, now: Time.now.to_i)
        write do
          db[:account_auth_transactions].where { expires_at <= now }.delete
          db[:account_auth_transactions].where(browser_hash: digest(browser)).delete
          db[:account_auth_transactions].insert(state_hash: digest(state), browser_hash: digest(browser),
                                                payload: payload, expires_at: now + 600)
          db[:account_sessions].where { (expires_at <= now) | (idle_until <= now) }.delete
          db[:accounts].where(status: 'deleted').where { deleted_at < now - MAX_SECONDS }.delete
        end
      end

      def consume_transaction(state, browser, now: Time.now.to_i)
        write do
          dataset = db[:account_auth_transactions].where(state_hash: digest(state), browser_hash: digest(browser))
          row = dataset.first
          dataset.delete
          row && row[:expires_at] > now ? row[:payload] : nil
        end
      end

      def claim_refresh(token, owner, now: Time.now.to_i)
        write do
          db[:account_sessions].where(id_hash: digest(token)).where { refresh_until <= now }
                               .update(refresh_owner: owner, refresh_until: now + 60) == 1
        end
      end

      def finish_refresh(token, owner, encrypted_tokens, expires_at)
        write do
          db[:account_sessions].where(id_hash: digest(token), refresh_owner: owner)
                               .update(tokens: encrypted_tokens, token_expires_at: expires_at,
                                       refresh_owner: nil, refresh_until: 0) == 1
        end
      end
    end
  end
end
