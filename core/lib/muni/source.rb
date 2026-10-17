require 'muni/helpers/http'

module Muni
  # Base class for every external data client.
  #
  #   class Cambridge::ServiceRequests < Muni::Source
  #     source :service_requests,
  #            hall:     'cambridge',
  #            emits:    Muni::Records::ServiceRequest,
  #            base_url: 'https://data.cambridgema.gov'
  #
  #     def pull(since: nil, limit: 500)
  #       rows = http.get('/datastore_search_sql', sql: ...)
  #       rows.dig('result', 'records').map { |r| emit(normalize(r)) }
  #     end
  #   end
  class Source
    class << self
      attr_accessor :emits, :auth_mode, :default_headers
      attr_reader :slug, :hall, :base_url, :cache_seconds, :domains, :categories,
                  :digest_role, :incident_kind, :cadence, :retention_days,
                  :inventory_mode, :criticality, :catalog, :waterbody, :municipalities

      def source(slug, emits:, base_url:, hall: nil, waterbody: nil, municipalities: [],
                 auth: :none, headers: {}, cache_seconds: nil,
                 domains: {}, categories: [], digest_role: nil, incident_kind: nil,
                 cadence: nil, retention_days: nil, inventory: :incremental,
                 criticality: :standard, catalog: {})
        set_scope(slug, hall: hall, waterbody: waterbody, municipalities: municipalities)
        @emits = emits
        @base_url = base_url
        @auth_mode = auth
        @default_headers = headers
        @cache_seconds = cache_seconds
        @domains = normalize_domains(domains)
        @categories = Array(categories).map(&:to_sym).freeze
        @digest_role = digest_role&.to_sym
        @incident_kind = incident_kind&.to_sym
        @cadence = cadence
        @retention_days = retention_days&.to_i
        @inventory_mode = inventory&.to_sym || :incremental
        @criticality = criticality&.to_sym || :standard
        @catalog = catalog.transform_keys(&:to_sym).freeze
        Muni::Registry.register_source(self)
      end

      def applicable_to_hall?(slug)
        hall == slug || municipalities.include?(slug)
      end

      private

      def set_scope(slug, hall:, waterbody:, municipalities:)
        raise ArgumentError, 'A source requires exactly one Hall or waterbody' if hall.nil? == waterbody.nil?

        @waterbody = waterbody
        @municipalities = Array(municipalities).map(&:to_s).freeze
        @slug = waterbody ? "water/#{waterbody}/#{slug}" : "#{hall}/#{slug}"
        @hall = hall
      end

      def normalize_domains(domains)
        values = domains.is_a?(Hash) ? domains : Array(domains).to_h { |domain| [domain, @hall] }
        values.to_h { |domain, provider| [domain.to_sym, provider.to_sym] }.freeze
      end
    end

    def initialize(opts = {})
      @opts = opts
      @http = Muni::Helpers::Http.new(base_url: self.class.base_url,
                                      headers:  self.class.default_headers || {})
    end

    # Subclasses override. Returns Array<Muni::Record>.
    def pull(since: nil, limit: nil)
      raise NotImplementedError, "#{self.class} must implement #pull"
    end

    # Beats prefer this streaming interface. Existing sources remain compatible
    # because their array-returning #pull implementation is yielded lazily here.
    def each_record(**args, &)
      return enum_for(__method__, **args) unless block_given?

      Array(pull(**args)).each(&)
    end

    # Optional streaming hook for SSE-style sources.
    def stream; end

    protected

    attr_reader :http

    def emit(attrs)
      self.class.emits.new(**attrs)
    end
  end
end
