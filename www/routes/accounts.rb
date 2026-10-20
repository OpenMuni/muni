require 'sinatra/base'
require_relative '../auth/service'
require_relative '../auth/helpers'

module Muni
  module Www
    module Routes
      class Accounts < Sinatra::Base
        SESSION_COOKIE = '__Host-muni_session'.freeze
        FLOW_COOKIE = '__Host-muni_flow'.freeze
        set :views, File.expand_path('../views', __dir__)
        set :public_folder, File.expand_path('../public', __dir__)
        set :host_authorization, { permitted_hosts: [] }
        set :show_exceptions, false
        set :dump_errors, false

        helpers Auth::Helpers

        before do
          unless request.path_info.match?(%r{\A/(?:login|signup|recover|logout(?:-all)?|account(?:/.*)?|auth/.*)\z})
            pass
          end
          halt 404, 'not found' unless %w[pilot public].include?(Auth.mode)

          headers 'Cache-Control' => 'no-store, private', 'Referrer-Policy' => 'no-referrer',
                  'X-Content-Type-Options' => 'nosniff', 'X-Frame-Options' => 'DENY',
                  'Content-Security-Policy' => "default-src 'none'; style-src 'self'; img-src 'self'; " \
                                               "form-action 'self' #{auth.config.domain}; " \
                                               "base-uri 'none'; frame-ancestors 'none'"
          ensure_origin!
        end

        get('/login') { start_flow('login') }
        get('/signup') { start_flow('signup', path: '/signup') }
        get('/recover') { start_flow('recover', path: '/forgotPassword') }

        get '/auth/cognito/callback' do
          result = auth.callback(state: params['state'], browser: request.cookies[FLOW_COOKIE],
                                 code: params['code'], previous: sid)
          cookie(FLOW_COOKIE, '', 0)
          if result[:recovery]
            clear_session
            log_event('recovery_completed')
            redirect auth.provider.logout_url
          end
          cookie(SESSION_COOKIE, result.fetch(:sid), Muni::Accounts::MAX_SECONDS)
          log_event('sign_in_completed')
          if result[:purpose] == 'enroll_start'
            row = auth.session(result[:sid])
            start_flow('enroll', path: '/passkeys/add', account: row.fetch(:account))
          end
          redirect '/account'
        end

        get '/account' do
          protected_account!
          render_account
        end

        post '/account/preference' do
          csrf!
          hall = Muni::Hall.all.find { |candidate| candidate.public? && candidate.slug == params['hall'] }
          halt 422, 'Choose an available city.' unless hall

          Muni::Accounts.preference(account_session[:account_id], hall.slug)
          response.set_cookie('hall', value: hall.slug, secure: true, same_site: :lax,
                                     path: '/', max_age: Muni::Accounts::MAX_SECONDS)
          redirect '/account', 303
        end

        post '/account/passkeys' do
          halt 404 unless Auth.passkeys_enabled?
          csrf!
          # Always refresh Cognito's browser session before enrollment, including when Muni is recently authenticated.
          start_flow('enroll_start', account: account_session[:account])
        end

        post '/account/passkeys/remove' do
          halt 404 unless Auth.passkeys_enabled?
          csrf!
          recent!
          tokens = account_session[:plaintext_tokens]
          id = params['credential_id'].to_s
          halt 422, 'Passkey not found.' unless auth.provider.credentials(tokens).any? do |item|
            item[:credential_id] == id
          end

          auth.provider.remove_credential(tokens, id)
          log_event('passkey_removed')
          redirect '/account', 303
        end

        post '/account/delete' do
          row = Muni::Accounts.session(sid)
          csrf!(row)
          recent!(row: row)
          halt 422, 'Confirm account deletion.' unless params['confirm'] == 'delete'

          id = row[:account_id]
          tokens = auth.vault.open(row[:tokens])
          Muni::Accounts.deletion_pending(id)
          @deletion_pending = true
          clear_session
          auth.provider.delete_user(tokens)
          Muni::Accounts.deletion_complete(id)
          log_event('account_deleted')
          redirect auth.provider.logout_url, 303
        end

        post '/logout' do
          # Logout must not depend on token refresh or provider availability.
          row = Muni::Accounts.session_record(sid)
          csrf!(row) if row
          halt 403 unless request.env['HTTP_ORIGIN'] == auth.config.base_url
          Muni::Accounts.remove_session(sid)
          clear_session
          begin
            auth.provider.revoke(auth.vault.open(row[:tokens])) if row
          rescue Auth::Error
            log_event('token_revocation_failed')
          end
          redirect auth.provider.logout_url, 303
        end

        post '/logout-all' do
          row = Muni::Accounts.session(sid)
          csrf!(row)
          recent!(row: row)
          Muni::Accounts.revoke_all(row[:account_id])
          clear_session
          auth.provider.global_sign_out(auth.vault.open(row[:tokens]))
          log_event('all_sessions_revoked')
          redirect auth.provider.logout_url, 303
        end

        get '/auth/signed-out' do
          clear_session
          @message = 'You are signed out. If you reset your password, sign in again to manage your passkeys.'
          erb :account_message, layout: :account_layout
        end

        error Auth::Error do
          log_event('authentication_failed')
          status env['sinatra.error'].is_a?(Auth::Unavailable) ? 503 : 400
          @message = if @deletion_pending
                       'Account access is disabled. Deletion is pending and will be retried by the service operator.'
                     else
                       'We could not complete this account request. Please sign in again or try later.'
                     end
          erb :account_message, layout: :account_layout
        end
      end
    end
  end
end
