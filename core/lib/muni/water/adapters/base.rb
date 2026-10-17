module Muni
  module Water
    module Adapters
      RECONCILIATION_KEYS = %w[validators reconciled_month archive_signature buoy_response_digest buoy_row_parser
                               buoy_row_fingerprints history_cursor history_start history_month routine_due_at].freeze

      # The caller holds the source lock before constructing or resetting its journal.
      def self.build(id, checkpoint:, now: Time.now.utc, reconcile: false)
        checkpoint = checkpoint.except(*RECONCILIATION_KEYS) if reconcile
        adapter = const_get(Catalog.definitions.fetch(id).fetch(:adapter)).new(id: id, checkpoint: checkpoint, now: now)
        adapter.client.discard_pending! if reconcile
        adapter
      end

      class Base
        attr_reader :locations, :metadata, :checkpoint, :client

        def initialize(id:, checkpoint: {}, now: Time.now.utc, client: nil)
          @id = id
          @checkpoint = checkpoint.dup
          @now = now
          @client = client || Client.new(checkpoint, slug: slug)
          @locations = []
          @metadata = checkpoint.fetch('metadata', {}).dup
        end

        def definition = Catalog.definitions.fetch(@id)
        def slug = "#{PREFIX}#{@id}"
        def url = definition.fetch(:url)

        def collect
          raise NotImplementedError, 'Water adapters must implement collect'
        end

        def record(id:, kind:, location_id:, raw:, payload: {}, **attributes)
          {
            external_id: Water.hash([slug, id.to_s]), source_slug: slug, waterbody: 'charles', kind: kind,
            location_id: location_id, source_url: url, parser_version: VERSION, status: 'published',
            fetched_at: retrieval_time, raw: raw, payload: payload.merge(source_record_id: id.to_s)
          }.merge(attributes)
        end

        def retrieval_time
          (client.last_retrieved_at if client.respond_to?(:last_retrieved_at)) || @now
        end

        def json(body)
          JSON.parse(body)
        rescue JSON::ParserError
          raise Error, 'Source response is not valid JSON'
        end

        def csv(body, required:)
          table = CSV.parse(body.sub(/\A\uFEFF/, ''), headers: true)
          raise Error, "Source schema missing: #{required.join(', ')}" unless (required - table.headers).empty?

          table
        rescue CSV::MalformedCSVError
          raise Error, 'Source response is not valid CSV'
        end

        def number(value)
          return nil if value.nil? || value.to_s.strip.empty?

          parsed = Float(value, exception: false)
          parsed if parsed&.finite?
        end

        def location(id:, name:, kind:, lon: nil, lat: nil, **attributes)
          longitude = number(lon)
          latitude = number(lat)
          plausible = longitude&.between?(-71.19, -71.05) && latitude&.between?(42.34, 42.39)
          row = { id: id, name: name, kind: kind, source_url: url, municipalities: HALLS,
                  geometry: plausible ? { type: 'Point', coordinates: [longitude, latitude] } : nil,
                  coordinate_status: plausible ? 'source_supplied' : 'unverified',
                  original_coordinates: [longitude, latitude] }.merge(attributes)
          @locations << row
          row
        end

        def remote_rows(path, params, &block)
          return enum_for(:remote_rows, path, params) unless block_given?

          fetch = ->(target, query) { client.get(target, query, conditional: false) }
          Muni::Clients::Arcgis.new(base_url: url, transport: client)
                               .each_page(path: path, params: params.transform_keys(&:to_s), fetch: fetch) do |batch|
            batch.each { |feature| feature['_muni_retrieved_at'] = retrieval_time }
            batch.each(&block)
            Thread.current[:muni_scheduler_yield]&.call
          end
        rescue Muni::Helpers::Http::Error => e
          raise if e.status != 200

          raise Error, e.message
        end
      end
    end
  end
end
