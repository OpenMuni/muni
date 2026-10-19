# Geometry projection uses conventional x/y names and writes a bounded checkpoint transaction.
# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Naming/MethodParameterName, Naming/PredicateMethod
require 'digest'
require 'json'

module Muni
  # Disposable geometry projection; municipal records remain authoritative.
  module ServiceRequestMap
    TABLE = :service_request_map_points
    VERSION = 1

    class Incomplete < StandardError; end

    class << self
      def ensure_schema!
        db.create_table?(TABLE) do
          String :hall, null: false
          String :external_id, null: false
          Float :lon, null: false
          Float :lat, null: false
          Float :x, null: false
          Float :y, null: false
          TrueClass :in_boundary, null: false
          primary_key %i[hall external_id]
          index %i[hall x y]
        end
        db.run(<<~SQL)
          CREATE TRIGGER IF NOT EXISTS service_request_map_delete
          AFTER DELETE ON service_requests BEGIN
            DELETE FROM service_request_map_points
            WHERE hall = OLD.hall AND external_id = OLD.external_id;
          END
        SQL
      end

      def fingerprint(hall)
        Digest::SHA256.hexdigest(JSON.generate([VERSION, Muni::Hall.find(hall)&.boundary]))
      end

      def state(hall)
        JSON.parse(Muni::Store.meta("efficiency:map:#{hall}") || '{}')
      rescue JSON::ParserError
        {}
      end

      def ready?(halls = Muni::Hall.all.select(&:public?).map(&:slug))
        indexed = !Muni::EfficiencyIndexes.matching_index(db, :service_requests, Muni::EfficiencyIndexes::MAP_COLUMNS).nil?
        indexed &&= !Muni::EfficiencyIndexes.matching_index(db, TABLE, Muni::EfficiencyIndexes::POINT_COLUMNS).nil?
        db.table_exists?(TABLE) && indexed && halls.all? do |hall|
          current = state(hall)
          current['complete'] == true && current['fingerprint'] == fingerprint(hall)
        end
      end

      def persist(row)
        key = row.slice(:hall, :external_id)
        coords = row[:location].is_a?(String) ? JSON.parse(row[:location]) : row[:location]
        point = coords.is_a?(Array) && Muni::Helpers::Geo.point(*coords.first(2))
        unless point.is_a?(Array) && point.all?(&:finite?)
          db[TABLE].where(key).delete
          return
        end
        lon, lat = point
        x, y = project(lon, lat)
        boundary = Muni::Hall.find(row[:hall])&.boundary
        attrs = key.merge(lon: lon, lat: lat, x: x, y: y,
                          in_boundary: Muni::Helpers::Geo.boundary_contains?(boundary, lon, lat))
        existing = db[TABLE].where(key).first
        return if existing == attrs

        db[TABLE].insert_conflict(target: %i[hall external_id], update: attrs.except(:hall, :external_id)).insert(attrs)
      rescue JSON::ParserError, ArgumentError, TypeError
        db[TABLE].where(key).delete
      end

      def project(lon, lat)
        latitude = lat.clamp(-85.05112878, 85.05112878) * Math::PI / 180
        [(lon + 180) / 360.0, (1 - (Math.log(Math.tan(latitude) + (1 / Math.cos(latitude))) / Math::PI)) / 2]
      end

      def unproject(x, y)
        [(x * 360) - 180, Math.atan(Math.sinh(Math::PI * (1 - (2 * y)))) * 180 / Math::PI]
      end

      # Checkpoint and projection updates share the writer lock and transaction.
      def rebuild!(batch_size: 1_000, max_batches: nil)
        batches = 0
        Muni::Hall.all.select(&:public?).each do |hall|
          loop do
            return false if max_batches && batches >= max_batches

            complete = Muni::Store.with_writer do
              db.transaction do
                current = state(hall.slug)
                signature = fingerprint(hall.slug)
                if current['fingerprint'] != signature
                  db[TABLE].where(hall: hall.slug).delete
                  current = { 'fingerprint' => signature }
                end
                next true if current['complete']

                rows = db[:service_requests].where(hall: hall.slug)
                rows = rows.where { external_id > current['after'] } if current['after']
                rows = rows.order(:external_id).limit(batch_size).select(:hall, :external_id, :location).all
                rows.each { |row| persist(row) }
                current['after'] = rows.last[:external_id] unless rows.empty?
                current['complete'] = rows.length < batch_size
                value = JSON.generate(current)
                meta = { key: "efficiency:map:#{hall.slug}", value: value, updated_at: Time.now.utc }
                db[:meta].insert_conflict(target: :key, update: meta.except(:key)).insert(meta)
                yield(hall: hall.slug, rows: rows.length, complete: current['complete']) if block_given?
                current['complete']
              end
            end
            batches += 1
            break if complete
          end
        end
        true
      end

      private

      def db
        Muni::Store.db
      end
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Naming/MethodParameterName, Naming/PredicateMethod
