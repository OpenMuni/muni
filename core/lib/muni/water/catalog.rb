module Muni
  module Water
    module Catalog
      MODEL = 'https://crwa-flagging.herokuapp.com/api/v1/model'.freeze
      BOATHOUSES = 'https://crwa-flagging.herokuapp.com/api/v1/boathouses'.freeze
      BUOY = 'https://www3.epa.gov/region1/buoys/charles/crbuoy.csv'.freeze
      WQP = 'https://waterqualitydata.us/wqx3'.freeze
      ARCGIS = 'https://services2.arcgis.com/Kuf0uTOqI2C0lE9a/arcgis/rest/services/' \
               '20201117_Database_test/FeatureServer/0'.freeze
      USGS = 'https://api.waterdata.usgs.gov/ogcapi/v1/collections'.freeze
      CAMBRIDGE = 'https://www.cambridgema.gov/departments/publicworks/combinedseweroverflowreporting'.freeze
      MWRA = 'https://www.mwra.com/our-environment/combined-sewer-overflow-cso-notifications/cso-table-export'.freeze
      STATIONS = {
        '700S' => '2', '715S' => '2', '729S' => '3', '743S' => '4',
        '763S' => '5', '773S' => '5', '784S' => '5',
        '1NBS' => '2', '2LARZ' => '3', '3BU' => '4', '4LONG' => '5'
      }.freeze
      OUTFALL_REACHES = { 'CAM005' => '3', 'CAM007' => '3', 'CAM017' => '5', 'MWR201' => '4',
                         'MWR018' => '5', 'MWR019' => '5', 'MWR020' => '5', 'MWR023' => '5' }.freeze
      DEFINITIONS = {
        'crwa_predictions' => { label: 'CRWA boating predictions', url: MODEL, cadence: 3600,
                                interval: 3600, grace: 14_400, adapter: :CrwaPredictions,
                                publication_cadence: 'Hourly during the boating season' },
        'crwa_boathouses'  => { label: 'CRWA boathouses and program states', url: BOATHOUSES,
                               cadence: 900, grace: 3600, adapter: :CrwaBoathouses,
                               publication_cadence: 'Overrides can change at any time' },
        'wqp'              => { label: 'CRWA laboratory archive · WQP', url: WQP, cadence: 604_800, adapter: :Wqp,
                               publication_cadence: 'WQX archive refreshes Thursday evenings; sample dates vary' },
        'crwa_laboratory'  => { label: 'CRWA published laboratory dashboard', url: ARCGIS,
                               cadence: 86_400, adapter: :CrwaLaboratory,
                               publication_cadence: 'Irregular archive updates; daily edition check' },
        'epa_buoy'         => { label: 'EPA Charles River buoy', url: BUOY, cadence: 1800,
                        interval: 900, grace: 7200, adapter: :Buoy,
                        publication_cadence: 'About 30-minute CSV batches observed; 15-minute readings' },
        'usgs'             => { label: 'USGS Waltham flow and level', url: USGS, cadence: 3600,
                    interval: 900, grace: 7200, adapter: :Usgs,
                    publication_cadence: 'Usually hourly transmission; 15-minute readings' },
        'cambridge_cso'    => { label: 'Cambridge reported sewage discharges', url: CAMBRIDGE,
                             cadence: 900, adapter: :CambridgeCso,
                             publication_cadence: 'Event-driven notices and corrections' },
        'mwra_cso'         => { label: 'MWRA reported sewage discharges', url: MWRA, cadence: 900, adapter: :MwraCso,
                               publication_cadence: 'Event-driven notices and corrections' }
      }.freeze
      CALENDARS = {
        'epa_buoy' => { minutes: [10, 40] }, 'usgs' => { minutes: [50] },
        'crwa_predictions' => { minutes: [10] }, 'wqp' => { weekday: 5, time: '04:00' },
        'crwa_laboratory' => { time: '05:00' }, 'crwa_boathouses' => { minutes: [0, 15, 30, 45] },
        'cambridge_cso' => { minutes: [0, 15, 30, 45] }, 'mwra_cso' => { minutes: [0, 15, 30, 45] }
      }.freeze
      DOCUMENTS = [
        { title: 'Draft updated CSO control plan · proposed projects',
          url:   'https://www.mwra.com/news/cambridge-somerville-and-mwra-submit-draft-updated-cso-control-plan' },
        { title: 'Cambridge stormwater annual reports',
          url:   'https://www.cambridgema.gov/departments/publicworks/initiatives/stormwatermanagement/annualreports' }
      ].freeze
      GAPS = [
        { id: 'bwsc', label: 'Boston Water and Sewer Commission', status: 'incomplete',
          url: 'https://www.bwsc.org/environment-education/maproom/' \
               'combined-sewer-overflow-map-and-public-notification' },
        { id: 'massdep', label: 'MassDEP incident portal', status: 'incomplete',
          url: 'https://eeaonline.eea.state.ma.us/portal/dep/cso-data-portal/' },
        { id: 'official_advisories', label: 'Government advisories · reviewed imports only', status: 'incomplete',
          url: 'https://www.mass.gov/info-details/cyanobacteria-and-recreational-freshwater' }
      ].freeze

      module_function

      def definitions
        DEFINITIONS.transform_values.with_index do |definition, index|
          id = DEFINITIONS.keys[index]
          override = ENV.fetch("MUNI_WATER_#{id.upcase}_INTERVAL", nil)
          cadence = (override || definition[:cadence]).to_i
          definition.merge(cadence: [cadence, 60].max, calendar: override ? nil : CALENDARS.fetch(id))
        end
      end

      def seed_locations
        [
          { id: 'epa-buoy', name: 'EPA buoy · outside Museum of Science', kind: 'sensor', reach_id: '5',
            source_url: 'https://www.epa.gov/charlesriver/live-water-quality-data-lower-charles-river',
            geometry: nil, note: 'Exact buoy coordinates not published in this feed; listed without a map marker.' },
          { id: 'USGS-01104500', name: 'Charles River at Waltham · upstream context', kind: 'gauge',
            source_url: "#{USGS}/monitoring-locations/items/USGS-01104500?f=json",
            geometry: { type: 'Point', coordinates: [-71.2336667544231, 42.3723185718895] } },
          { id: 'CAM005', name: 'CAM005 · downstream of Eliot Bridge', kind: 'outfall', reach_id: '3',
            operator: 'City of Cambridge', source_url: CAMBRIDGE, geometry: nil }
        ]
      end
    end
  end
end
