require_relative 'config'

module Muni
  module Www
    module Auth
      module Navigation
        def navigation_account
          # Every version of this HTML varies by cookie, including signed-out and disabled responses.
          headers 'Cache-Control' => 'no-store, private',
                  'Vary'          => [response['Vary'], 'Cookie'].compact.join(', ')
          return nil unless Auth.mode == 'public'

          # Decoration only: protected account routes still validate/refresh Cognito tokens.
          # Public browsing must never require provider configuration or a network call.
          Muni::Accounts.session(request.cookies['__Host-muni_session'])&.fetch(:account)
        rescue Sequel::DatabaseError
          nil
        end
      end
    end
  end
end
