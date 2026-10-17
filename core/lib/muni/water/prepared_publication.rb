module Muni
  module Water
    # Constructed under the source's exclusive collection lock, before the shared
    # writer lock. Source cursors and publication state commit with the evidence.
    class PreparedPublication
      attr_reader :run_metadata

      def initialize(slug, adapter, publisher_observations:, dirty:, now:)
        @checkpoint = checkpoint_row(slug, adapter, publisher_observations, now)
        @locations = adapter.locations.map do |location|
          value = Water.canonical(location)
          { id: value.fetch('id'), waterbody: 'charles', payload: Water.json(value) }
        end
        @run_metadata = Water.json(adapter.metadata)
        @calculation_prefix = "{\"dirty\":#{Water.json(dirty)},\"revision_range\":["
      end

      def publish
        @locations.each do |row|
          Storage.db[:water_locations].insert_conflict(target: :id, update: row).insert(row)
        end
        Storage.db[:water_checkpoints].insert_conflict(target: :source_slug, update: @checkpoint).insert(@checkpoint)
      end

      # The small revision range is known only after publication. The potentially
      # large dirty-day tree was already encoded during preparation.
      def calculation_payload(first, last)
        "#{@calculation_prefix}#{Integer(first)},#{Integer(last)}]}"
      end

      private

      def checkpoint_row(slug, adapter, publisher_observations, now)
        previous = Storage.checkpoint(slug)
        # Preserve adapter deletions of completed cursors instead of merging old keys back in.
        checkpoint = adapter.checkpoint.merge('validators' => adapter.client.validators)
        checkpoint['monitoring_started_at'] ||= previous['monitoring_started_at'] || now.iso8601
        checkpoint['last_success_at'] = now.iso8601
        checkpoint['metadata'] = previous.fetch('metadata', {}).merge(checkpoint.fetch('metadata', {}))
                                         .merge(adapter.metadata)
        checkpoint['last_checked_at'] = Time.now.utc.iso8601
        checkpoint['publisher_observations'] = publisher_observations
        { source_slug: slug, payload: Water.json(checkpoint) }
      end
    end
  end
end
