require 'muni/record'

module Muni
  module Records
    class TrafficVolumeDaily < Muni::Record
      schema do
        string  :external_id, primary: true
        string  :hall
        string  :intersection_id
        text    :intersection
        string  :vehicle_class
        integer :count
        point   :location
        time    :observed_at
        string  :source_url
        time    :collected_at
        time    :last_seen_at
      end
    end
  end
end
