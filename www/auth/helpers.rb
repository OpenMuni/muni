require 'ipaddr'

module Muni
  module Www
    module Auth
      module Helpers
        def auth = Auth.service
        def h(value) = Rack::Utils.escape_html(value.to_s)
        def sid = request.cookies['__Host-muni_session']
        def account_session = @account_session ||= auth.session(sid)

        def cookie(name, value, max_age)
          response.set_cookie(name, value: value, secure: true, httponly: true, same_site: :lax,
                                    path: '/', max_age: max_age)
        end

        def clear_session
          cookie('__Host-muni_session', '', 0)
        end

        def protected_account!
          redirect '/login' unless account_session
        end

        def csrf!
          protected_account!
          valid = request.env['HTTP_ORIGIN'] == auth.config.base_url &&
                  Rack::Utils.secure_compare(params['csrf'].to_s, account_session[:csrf])
          halt 403, 'Please reload the account page and try again.' unless valid
        end

        def start_flow(purpose, path: '/oauth2/authorize', account: nil)
          browser = SecureRandom.urlsafe_base64(32)
          cookie('__Host-muni_flow', browser, 600)
          redirect auth.begin_flow(purpose: purpose, browser: browser, path: path, account: account)
        end

        def recent!(purpose = 'reauth')
          return if account_session[:auth_time] > Time.now.to_i - 300

          start_flow(purpose, account: account_session[:account])
        end

        def render_account(message = nil)
          @account = account_session[:account]
          @csrf = account_session[:csrf]
          @credentials = Auth.passkeys_enabled? ? auth.provider.credentials(account_session[:plaintext_tokens]) : []
          @message = message
          erb :account, layout: :account_layout
        end

        def ensure_origin!
          expected_host = URI(auth.config.base_url).host
          halt 400, 'Invalid account host' unless request.env['HTTP_HOST'] == expected_host

          forwarded = request.env['HTTP_X_FORWARDED_PROTO']
          remote = request.env['REMOTE_ADDR'].to_s
          trusted = ENV.fetch('MUNI_AUTH_TRUSTED_PROXIES', '127.0.0.1/32,::1/128').split(',')
                       .any? { |cidr| IPAddr.new(cidr).include?(remote) }
          secure = request.env['rack.url_scheme'] == 'https' || (trusted && forwarded == 'https')
          halt 400, 'HTTPS is required' unless secure
          halt 400, 'Invalid forwarded host' if request.env['HTTP_X_FORWARDED_HOST'] &&
                                                request.env['HTTP_X_FORWARDED_HOST'] != expected_host
        rescue IPAddr::InvalidAddressError
          halt 400, 'Invalid proxy configuration'
        end

        def log_event(event)
          Muni::Logger.instance.info(JSON.generate(component: 'accounts', event: event))
        end
      end
    end
  end
end
