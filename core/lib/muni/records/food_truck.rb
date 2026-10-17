require 'muni/record'

module Muni
  module Records
    class FoodTruck < Muni::Record
      schema do
        string  :external_id, primary: true
        string  :hall
        string  :status
        string  :permit_id
        string  :viewpoint_id
        string  :business_name
        string  :dba
        string  :truck_name
        text    :items_to_be_sold
        text    :equipment
        string  :refrigeration_method
        string  :soft_serve_machine
        integer :food_handler_count
        string  :sanitizer_type
        string  :weekday
        string  :hours
        string  :open_time
        string  :close_time
        string  :address
        string  :business_address
        string  :prep_location
        string  :toilet_facilities
        time    :applicant_submit_date
        time    :issued_at
        time    :food_protection_certification_expires_at
        time    :allergen_awareness_certification_expires_at
        time    :attested_at
        point   :location
        string  :source_url
        time    :collected_at
        time    :last_seen_at
      end
    end
  end
end
