require 'muni/record'

module Muni
  module Records
    class CpdCrash < Muni::Record
      schema do
        string  :external_id, primary: true
        string  :hall
        text    :location_description
        string  :neighborhood
        integer :motorists
        integer :cyclists
        integer :pedestrians
        integer :injuries
        integer :hospitalizations
        boolean :injury
        boolean :cyclist
        boolean :pedestrian
        point   :location
        time    :occurred_at
        string  :source_url
        time    :collected_at
        time    :last_seen_at
      end
    end
  end
end
