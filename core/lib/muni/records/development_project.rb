require 'muni/record'

module Muni
  module Records
    class DevelopmentProject < Muni::Record
      schema do
        string  :external_id, primary: true
        string  :hall
        string  :name
        string  :status
        string  :address
        point   :location
        string  :primary_use
        string  :project_type
        integer :residential_units
        integer :affordable_units
        float   :gross_floor_area
        float   :far
        string  :developer
        string  :neighborhood
        string  :zoning
        string  :building_permit
        integer :year_complete
        string  :description
        string  :source_url
        time    :collected_at
        time    :last_seen_at
      end
    end
  end
end
