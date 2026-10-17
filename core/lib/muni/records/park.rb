require 'muni/record'

module Muni
  module Records
    class Park < Muni::Record
      schema do
        string  :external_id, primary: true
        string  :hall
        string  :name
        string  :owner
        string  :park_type
        integer :fcode
        integer :oscode
        integer :rcode
        float   :acres
        time    :edited_at
        point   :location
        json    :geometry
        string  :source_url
        time    :collected_at
        time    :last_seen_at
      end
    end
  end
end
