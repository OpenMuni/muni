require 'muni/record'

module Muni
  module Records
    class Crash < Muni::Record
      schema do
        string  :external_id, primary: true
        string  :hall
        string  :crash_type
        boolean :injury
        boolean :fatal
        boolean :cyclist
        boolean :pedestrian
        string  :manner
        string  :first_harmful_event
        string  :day_of_week
        text    :location_description
        point   :location
        time    :occurred_at
        string  :source_url
        time    :collected_at
        time    :last_seen_at
      end
    end
  end
end
