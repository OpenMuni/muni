# frozen_string_literal: true

require 'muni/transit/client'

module Muni
  # Regional subway data fetched only by the server from MBTA V3.
  module Transit
    ROUTES = %w[Red Orange Blue Green-B Green-C Green-D Green-E Mattapan].freeze

    class << self
      def stations = Client.stations
      def vehicles = Client.vehicles
      def predictions(stop_id:) = Client.predictions(stop_id: stop_id)
      def alerts = Client.alerts
    end
  end
end
