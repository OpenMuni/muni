module Muni
  module Www
    module Routes
      module HallResolution
        ADMIN_ROOT_HOSTS = %w[admin.muni.fyi].freeze
        PUBLIC_ROOT_HOSTS = %w[muni.fyi www.muni.fyi].freeze

        def resolved_hall_slug(default: 'cambridge')
          requested = params[:hall].to_s.strip
          return requested unless requested.empty?

          host_hall_slug || default
        end

        def resolved_hall(default: 'cambridge')
          slug = resolved_hall_slug(default: default)
          public_hall(slug) || halt(404, "unknown Hall: #{slug}")
        end

        def public_hall(slug)
          hall = Muni::Hall.find(slug)
          hall if hall&.public?
        end

        def host_hall_slug
          slug = requested_host_hall_slug
          slug && public_hall(slug)&.slug
        end

        def requested_host_hall_slug
          host = request.host.to_s.downcase
          return nil if host.empty?
          return nil if ADMIN_ROOT_HOSTS.include?(host) || PUBLIC_ROOT_HOSTS.include?(host)
          return nil unless host.end_with?('.muni.fyi')

          slug = host.delete_suffix('.muni.fyi')
          return nil if slug.empty? || slug.include?('.')

          slug
        end

        def apply_host_hall_param!
          requested = requested_host_hall_slug
          halt 404, JSON.dump(error: "unknown Hall: #{requested}") if requested && !public_hall(requested)
          hall = host_hall_slug
          return unless hall

          params['hall'] = hall if params['hall'].to_s.empty?
          params[:hall] = hall if params[:hall].to_s.empty?
        end

        def page_hall!
          explicit = params[:hall].to_s.strip
          explicit = requested_host_hall_slug.to_s if explicit.empty? && requested_host_hall_slug
          return public_hall(explicit) || halt(404, "unknown Hall: #{explicit}") unless explicit.empty?

          cookie = request.cookies['hall'].to_s
          public_hall(cookie) || public_hall('cambridge') || halt(404, 'no public Hall configured')
        end
      end
    end
  end
end
