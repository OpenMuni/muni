require 'json'

module Muni
  # A cached spatial layer (GeoJSON blob) backing map views.
  Plat = Struct.new(:slug, :geojson, keyword_init: true) do
    def save!
      Muni::Store.with_writer do
        ds = Muni::Store.db[:geo_layers]
        encoded = geojson.is_a?(String) ? geojson : JSON.generate(geojson)
        ds.insert_conflict(target: :slug,
                           update: { geojson: encoded, updated_at: Sequel::CURRENT_TIMESTAMP })
          .insert(slug: slug, geojson: encoded)
      end
      self
    end

    def self.find(slug)
      row = Muni::Store.db[:geo_layers].where(slug: slug).first
      return nil unless row

      new(slug: slug, geojson: JSON.parse(row[:geojson]))
    end
  end
end
