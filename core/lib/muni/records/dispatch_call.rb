require 'muni/record'

module Muni
  module Records
    class DispatchCall < Muni::Record
      schema do
        string :external_id, primary: true
        string :hall
        string :agency
        string :incident_type
        string :incident_group
        string :priority
        text   :address
        text   :intersection
        string :reporting_area
        string :firebox
        string :police_sector
        string :police_route
        string :ladder_district
        string :engine_district
        string :neighborhood
        text   :location_description
        point  :location
        time   :received_at
        time   :closed_at
        string :source_url
        time   :collected_at
        time   :last_seen_at
      end
    end
  end
end
