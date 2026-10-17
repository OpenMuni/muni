require 'muni/record'

module Muni
  module Records
    class PoliceLogEntry < Muni::Record
      schema do
        string  :external_id, primary: true
        string  :hall
        string  :crime_category
        string  :crime_subcategory
        text    :description
        string  :neighborhood
        point   :location
        time    :occurred_at
        time    :reported_at
        string  :source_url
        time    :collected_at
        time    :last_seen_at
      end
    end
  end
end
