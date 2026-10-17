require 'muni/record'

module Muni
  module Records
    class Tree < Muni::Record
      schema do
        string  :external_id, primary: true
        string  :hall
        string  :species_common
        string  :species_scientific
        float   :diameter_in
        string  :condition
        string  :ownership
        time    :plant_date
        time    :removal_date
        string  :order_number
        text    :notes
        point   :location
        string  :source_url
        time    :collected_at
        time    :last_seen_at
      end
    end
  end
end
