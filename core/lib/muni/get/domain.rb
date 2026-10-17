module Muni
  module Get
    # A user-facing data domain (311, police, permits, …) mapped to one or more providers.
    Domain = Struct.new(
      :slug,
      :title,
      :providers,
      :default_provider,
      :requires_zone,
      :aliases,
      keyword_init: true
    ) do
      def initialize(*)
        super
        self.aliases ||= []
        self.providers ||= {}
        self.requires_zone = false if requires_zone.nil?
      end

      def provider(key)
        providers[key.to_sym] or providers[key.to_s]
      end

      def provider_keys
        providers.keys
      end
    end
  end
end
