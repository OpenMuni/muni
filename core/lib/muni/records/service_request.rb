require 'muni/record'

module Muni
  module Records
    class ServiceRequest < Muni::Record
      schema do
        string  :external_id, primary: true
        string  :hall
        string  :case_type
        string  :status
        string  :department
        string  :neighborhood
        text    :description
        string  :address
        point   :location
        time    :opened_at
        time    :updated_at
        time    :acknowledged_at
        time    :closed_at
        string  :image_url
        string  :source_url
        time    :collected_at
        time    :last_seen_at
        time    :source_revision_at
        json    :lifecycle_evidence
        string  :lifecycle_source_state
        time    :lifecycle_checked_at
      end
    end
  end
end
