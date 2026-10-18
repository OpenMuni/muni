# frozen_string_literal: true

require 'muni/transit/stations'
require 'muni/transit/performance'
require 'muni/transit/client'

module Muni
  # Regional MBTA Rapid Transit and Commuter Rail intelligence.
  module Transit
    HALLS = %w[cambridge boston].freeze

    class << self
      def stations(hall: nil)
        Stations.for_hall(hall)
      end

      def station(id)
        Stations.find(id)
      end

      def geojson(hall: nil)
        Stations.to_geojson(hall: hall)
      end

      def performance(hall: nil)
        hall ? Performance.summary_for(hall) : Performance.system_overview
      end

      def lines(corridor: nil)
        Performance.lines(corridor: corridor)
      end

      def vehicles(routes: nil)
        r = routes || (Performance::CAMBRIDGE_ROUTES + Performance::BOSTON_ROUTES).uniq
        Client.vehicles(routes: r)
      end

      def predictions(stop_id:)
        Client.predictions(stop_id: stop_id)
      end

      def alerts(route: nil)
        Client.alerts(route: route)
      end
    end
  end
end
