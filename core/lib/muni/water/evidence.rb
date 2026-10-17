module Muni
  module Water
    # One shared identity per piece of evidence; kind keeps measurements,
    # predictions, notices, and publisher states distinct in every read path.
    class Evidence < Muni::Record
      def self.slug = 'water_evidence'

      schema do
        string :external_id, primary: true
        string :source_slug, indexed: true
        string :waterbody
        string :kind, indexed: true
        string :location_id, indexed: true
        string :reach_id
        string :parameter
        float :value
        string :unit
        string :method
        string :segment
        string :status
        time :observed_at, indexed: true
        string :observed_date, indexed: true
        string :time_precision
        string :publication_group_id, indexed: true
        string :normalization_version
        time :published_at
        time :fetched_at
        string :original_timezone
        string :source_url
        string :parser_version
        json :payload
        json :raw
      end
    end
  end
end
