require 'muni/record'

module Muni
  module Records
    class MeteredParkingSpace < Muni::Record
      schema do
        string  :external_id, primary: true
        string  :hall
        string  :space_id, indexed: true
        string  :pay_by_phone_zone
        integer :max_minutes
        string  :max_time_label
        float   :hourly_rate
        string  :rate_label
        float   :minutes_per_payment
        string  :operation_hours
        string  :operation_window
        string  :rule_status
        string  :smart_meter
        point   :location
        json    :geometry
        string  :source_url
        time    :collected_at
        time    :last_seen_at
      end
    end
  end
end
