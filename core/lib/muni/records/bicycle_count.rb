require 'muni/record'

module Muni
  module Records
    class BicycleCount < Muni::Record
      schema do
        string  :external_id, primary: true
        string  :hall
        text    :count_location
        string  :street
        string  :traffic_direction
        string  :cyclist_location
        string  :cyclist_direction
        string  :movement_type
        integer :count
        float   :temperature
        string  :weather
        text    :notes
        string  :node_number
        point   :location
        time    :observed_at
        string  :source_url
        time    :collected_at
        time    :last_seen_at
      end
    end
  end
end
