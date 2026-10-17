require 'muni/record'

module Muni
  module Records
    class BuildingPermit < Muni::Record
      schema do
        string  :external_id, primary: true
        string  :hall
        string  :permit_type
        string  :status
        string  :description
        string  :address
        point   :location
        float   :declared_valuation
        time    :applied_at
        time    :issued_at
        string  :property_use
        string  :proposed_use
        string  :mbl
        string  :source_url
        time    :collected_at
        time    :last_seen_at
      end
    end
  end
end
