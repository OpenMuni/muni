require 'muni/helpers/normalize'

module Muni
  module Get
    # Fetches normalized records for a domain, honoring zone (hall) and provider.
    class Runner
      Result = Struct.new(:domain, :zone, :provider, :source, :record_type, :records, :live, keyword_init: true) do
        def to_h
          {
            domain:      domain,
            zone:        zone&.to_h,
            provider:    provider.to_s,
            source:      source,
            record_type: record_type,
            live:        live,
            count:       records.size,
            records:     records.map { |r| r.is_a?(Hash) ? r : r.to_h }
          }
        end
      end

      def initialize(domain:, zone: nil, provider: nil, since: nil, limit: 25, live: true, persist: false)
        @domain = domain.is_a?(Domain) ? domain : Registry.find!(domain)
        @zone = zone
        @provider_key = provider&.to_sym
        @since = since
        @limit = limit
        @live = live
        @persist = persist
      end

      def call
        binding = resolve_binding
        records = if @live
                    pull_live(binding)
                  else
                    query_store(binding)
                  end
        records = apply_filter(records, binding.provider)

        Result.new(
          domain:      @domain.slug,
          zone:        @zone,
          provider:    binding.provider.key,
          source:      binding.provider.source_slug,
          record_type: binding.provider.record_slug,
          records:     records,
          live:        @live
        )
      end

      Binding = Struct.new(:provider, :zone, keyword_init: true)

      private

      def resolve_binding
        provider = resolve_provider
        Binding.new(provider: provider, zone: @zone)
      end

      def resolve_provider
        key = @provider_key || infer_provider_key
        prov = @domain.provider(key)
        return prov if prov

        available = @domain.provider_keys.join(', ')
        raise ArgumentError,
              "provider #{key.inspect} not available for #{@domain.slug} (try: #{available})"
      end

      def infer_provider_key
        if @domain.default_provider
          @domain.default_provider
        elsif @zone
          @zone.slug.to_sym
        else
          raise ArgumentError,
                "#{@domain.slug} requires a zone (e.g. cambridge,ma) or --provider=..."
        end
      end

      def pull_live(binding)
        klass = binding.provider.source_class
        opts = (binding.provider.pull_options || {}).dup
        opts[:since] = @since if @since
        opts[:limit] = @limit if @limit
        records = Array(klass.new.pull(**opts))
        records.each { |r| Muni::Store.upsert(r) } if @persist
        records
      end

      def query_store(binding)
        Muni::Data.records_for_type(
          binding.provider.record_slug,
          hall:  @zone&.slug,
          since: @since,
          limit: @limit
        )
      end

      def apply_filter(records, provider)
        return records unless provider.row_filter

        records.select { |row| provider.row_filter.call(row) }
      end
    end
  end
end
