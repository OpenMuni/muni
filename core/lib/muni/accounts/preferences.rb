module Muni
  module Accounts
    class InvalidPreference < StandardError; end

    module Preferences
      EMPTY = { home_station_network: nil, home_station_line: nil, home_station_id: nil }.freeze
      NETWORKS = { 'boston' => 'mbta', 'cambridge' => 'mbta' }.freeze

      class << self
        def network_for(hall) = NETWORKS[hall]

        def validate(hall, line:, station:)
          validate_city!(hall)
          return {} if line.nil? && station.nil?

          unless line.is_a?(String) && station.is_a?(String)
            raise InvalidPreference, 'Choose a train line and station from the available options.'
          end
          return EMPTY if line.empty? && station.empty?

          unless network_for(hall) == 'mbta' && Transit::ROUTES.include?(line)
            raise InvalidPreference, 'Choose an available MBTA train line for your city.'
          end

          validate_station!(line, station) unless station.empty?
          { home_station_network: 'mbta', home_station_line: line, home_station_id: station.empty? ? nil : station }
        end

        def validate_city!(hall)
          valid = hall.is_a?(String) && Muni::Hall.all.any? { |candidate| candidate.public? && candidate.slug == hall }
          raise InvalidPreference, 'Choose an available city.' unless valid
        end

        def validate_station!(line, station)
          valid = station.start_with?('place-') && Transit.stations.fetch('data').any? do |candidate|
            candidate['id'] == station && candidate.fetch('routes').include?(line)
          end
          raise InvalidPreference, 'Choose a station served by the selected train line.' unless valid
        end
      end
    end
  end
end
