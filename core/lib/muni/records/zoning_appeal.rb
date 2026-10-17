require 'muni/record'

module Muni
  module Records
    class ZoningAppeal < Muni::Record
      schema do
        string  :external_id, primary: true
        string  :hall
        string  :status
        string  :address
        point   :location
        string  :current_use
        string  :proposed_use
        string  :zoning_district
        string  :relief
        integer :dwelling_units_requested
        time    :applied_at
        time    :hearing_deadline_at
        time    :decided_at
        string  :source_url
        time    :collected_at
        time    :last_seen_at
      end
    end
  end
end
