require 'muni/record'

module Muni
  module Records
    class CrimeReport < Muni::Record
      schema do
        string :external_id, primary: true
        string :hall
        string :crime_category
        text   :crime_date_time
        string :reporting_area
        string :neighborhood
        text   :location_description
        point  :location
        time   :occurred_at
        time   :reported_at
        string :source_url
        time   :collected_at
        time   :last_seen_at
      end
    end
  end
end
