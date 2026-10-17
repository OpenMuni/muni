require 'muni/record'

module Muni
  module Records
    class PedestrianCountDaily < Muni::Record
      schema do
        string  :external_id, primary: true
        string  :hall
        text    :intersection
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
