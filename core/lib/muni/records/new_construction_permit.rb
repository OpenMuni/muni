require 'muni/record'

module Muni
  module Records
    class NewConstructionPermit < Muni::Record
      schema do
        string  :external_id, primary: true
        string  :hall
        string  :status
        string  :address
        point   :location
        string  :proposed_use
        string  :construction_type
        integer :dwelling_units
        float   :gross_square_footage
        float   :declared_valuation
        string  :description
        string  :mbl
        time    :applied_at
        time    :issued_at
        string  :source_url
        time    :collected_at
        time    :last_seen_at
      end
    end
  end
end
