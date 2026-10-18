module Muni
  # Title/subtitle formatters for web list and detail panes.
  module Display
    TITLE_FIELDS = {
      'Muni::Records::ServiceRequest'       => %i[case_type description external_id],
      'Muni::Records::PoliceLogEntry'       => %i[crime_subcategory description crime_category external_id],
      'Muni::Records::CrimeReport'          => %i[crime_category location_description external_id],
      'Muni::Records::DispatchCall'         => %i[incident_type incident_group address external_id],
      'Muni::Records::CpdCrash'             => %i[location_description neighborhood external_id],
      'Muni::Records::TrafficVolumeDaily'   => %i[intersection vehicle_class external_id],
      'Muni::Records::BicycleCount'         => %i[count_location street external_id],
      'Muni::Records::PedestrianCountDaily' => %i[intersection external_id],
      'Muni::Records::BuildingPermit'       => %i[permit_type description external_id],
      'Muni::Records::Tree'                 => %i[species_common species_scientific external_id],
      'Muni::Records::Park'                 => %i[name park_type external_id],
      'Muni::Records::Crash'                => %i[crash_type location_description external_id],
      'Muni::Records::FoodTruck'            => %i[truck_name dba business_name external_id],
      'Muni::Records::MeteredParkingSpace'  => %i[space_id max_time_label external_id],
      'Muni::Records::DigestItem'           => %i[title external_id],
      'Muni::Transit::Station'              => %i[name code external_id]
    }.freeze

    SUBTITLE_FIELDS = {
      'Muni::Records::ServiceRequest'       => %i[description neighborhood department],
      'Muni::Records::PoliceLogEntry'       => %i[description neighborhood reported_at],
      'Muni::Records::CrimeReport'          => %i[location_description neighborhood reported_at],
      'Muni::Records::DispatchCall'         => %i[address intersection neighborhood received_at],
      'Muni::Records::CpdCrash'             => %i[neighborhood occurred_at],
      'Muni::Records::TrafficVolumeDaily'   => %i[vehicle_class observed_at],
      'Muni::Records::BicycleCount'         => %i[street observed_at],
      'Muni::Records::PedestrianCountDaily' => %i[observed_at],
      'Muni::Records::BuildingPermit'       => %i[address status],
      'Muni::Records::Tree'                 => %i[species_scientific condition],
      'Muni::Records::Park'                 => %i[park_type owner],
      'Muni::Records::Crash'                => %i[location_description occurred_at],
      'Muni::Records::FoodTruck'            => %i[schedule_summary address items_to_be_sold business_name status],
      'Muni::Records::MeteredParkingSpace'  => %i[operation_window rate_label pay_by_phone_zone],
      'Muni::Records::DigestItem'           => %i[summary location_name source_name],
      'Muni::Transit::Station'              => %i[lines hall]
    }.freeze

    DEFAULT_TITLE    = %i[case_type name permit_type crime_category crash_type species_common external_id].freeze
    DEFAULT_SUBTITLE = %i[neighborhood address location_description status].freeze
    FIELD_LABELS = {
      external_id:                                 'Record ID',
      hall:                                        'Municipality',
      case_type:                                   'Case type',
      status:                                      'Status',
      display_status:                              'Status',
      department:                                  'Department',
      neighborhood:                                'Neighborhood',
      description:                                 'Description',
      address:                                     'Address',
      opened_at:                                   'Opened',
      updated_at:                                  'Updated',
      acknowledged_at:                             'Acknowledged',
      closed_at:                                   'Closed',
      image_url:                                   'Image',
      source_url:                                  'Source',
      crime_category:                              'Category',
      crime_subcategory:                           'Case type',
      crime_date_time:                             'Crime time',
      reporting_area:                              'Reporting area',
      occurred_at:                                 'Occurred',
      reported_at:                                 'Reported',
      last_touched_at:                             'Last touched',
      map_visible:                                 'Map visible',
      agency:                                      'Agency',
      incident_type:                               'Type',
      incident_group:                              'Group',
      priority:                                    'Priority',
      intersection:                                'Intersection',
      firebox:                                     'Fire box',
      police_sector:                               'Police sector',
      police_route:                                'Police route',
      ladder_district:                             'Ladder district',
      engine_district:                             'Engine district',
      received_at:                                 'Received',
      permit_type:                                 'Permit type',
      declared_valuation:                          'Declared value',
      applied_at:                                  'Applied',
      issued_at:                                   'Issued',
      property_use:                                'Current use',
      proposed_use:                                'Proposed use',
      mbl:                                         'Parcel',
      crash_type:                                  'Crash type',
      motorists:                                   'Motorists',
      cyclists:                                    'Cyclists',
      pedestrians:                                 'Pedestrians',
      injuries:                                    'Injuries',
      hospitalizations:                            'Hospitalizations',
      injury:                                      'Injury',
      fatal:                                       'Fatal',
      cyclist:                                     'Cyclist involved',
      pedestrian:                                  'Pedestrian involved',
      manner:                                      'Collision manner',
      first_harmful_event:                         'First harmful event',
      day_of_week:                                 'Day',
      location_description:                        'Location',
      violation_description:                       'Violation',
      violation_code:                              'Violation code',
      meter:                                       'Meter',
      location_type:                               'Location type',
      amount_due:                                  'Amount due',
      vehicle_class:                               'Class',
      intersection_id:                             'Intersection ID',
      count:                                       'Count',
      observed_at:                                 'Observed',
      count_location:                              'Count location',
      traffic_direction:                           'Traffic direction',
      cyclist_location:                            'Cyclist location',
      cyclist_direction:                           'Cyclist direction',
      movement_type:                               'Movement',
      temperature:                                 'Temperature',
      weather:                                     'Weather',
      node_number:                                 'Node',
      species_common:                              'Species/site',
      species_scientific:                          'Scientific name',
      diameter_in:                                 'Diameter',
      condition:                                   'Condition',
      ownership:                                   'Ownership',
      name:                                        'Name',
      owner:                                       'Owner',
      park_type:                                   'Kind',
      fcode:                                       'Feature code',
      oscode:                                      'Open-space code',
      rcode:                                       'Recreation code',
      acres:                                       'Acres',
      edited_at:                                   'Edited',
      plant_date:                                  'Planted',
      removal_date:                                'Removed',
      order_number:                                'Work order',
      notes:                                       'Notes',
      permit_id:                                   'Permit ID',
      viewpoint_id:                                'ViewPoint ID',
      business_id:                                 'Business ID',
      business_name:                               'Business',
      dba:                                         'DBA',
      truck_name:                                  'Truck',
      space_id:                                    'Space ID',
      pay_by_phone_zone:                           'Pay by phone zone',
      max_minutes:                                 'Max stay',
      max_time_label:                              'Max stay',
      hourly_rate:                                 'Hourly rate',
      rate_label:                                  'Rate',
      minutes_per_payment:                         'Minutes per payment',
      operation_hours:                             'Operation hours',
      operation_window:                            'Hours',
      rule_status:                                 'Rule status',
      smart_meter:                                 'Smart meter',
      meter_status:                                'Meter status',
      meter_status_key:                            'Meter status',
      geometry:                                    'Geometry',
      items_to_be_sold:                            'Items sold',
      equipment:                                   'Equipment',
      refrigeration_method:                        'Refrigeration',
      soft_serve_machine:                          'Soft serve machine',
      food_handler_count:                          'Food handlers',
      sanitizer_type:                              'Sanitizer',
      weekday:                                     'Day',
      hours:                                       'Hours',
      schedule_summary:                            'Schedule',
      open_time:                                   'Opens',
      close_time:                                  'Closes',
      business_address:                            'Business address',
      prep_location:                               'Off-site prep',
      toilet_facilities:                           'Toilet facilities',
      applicant_submit_date:                       'Submitted',
      food_protection_certification_expires_at:    'Food protection expires',
      allergen_awareness_certification_expires_at: 'Allergen awareness expires',
      attested_at:                                 'Attested',
      location:                                    'Coordinates',
      collected_at:                                'Collected',
      last_seen_at:                                'Last seen',
      source_name:                                 'Source',
      source_type:                                 'Source type',
      item_type:                                   'Item type',
      section_hint:                                'Section',
      title:                                       'Title',
      summary:                                     'Summary',
      category:                                    'Category',
      url:                                         'URL',
      published_at:                                'Published',
      event_start_at:                              'Starts',
      event_end_at:                                'Ends',
      fetched_at:                                  'Fetched',
      first_seen_at:                               'First seen',
      location_name:                               'Location',
      tags:                                        'Tags',
      confidence:                                  'Confidence',
      freshness_score:                             'Freshness',
      dedupe_key:                                  'Dedupe key',
      metadata:                                    'Metadata',
      _source_slug:                                'Source feed'
    }.freeze
    META_FIELDS = {
      'Muni::Records::ServiceRequest'       => [
        { label: 'Status', field: :display_status, tone: :status },
        { label: 'Reported', field: :reported_at, format: :short_date },
        { label: 'Department', field: :department },
        { label: 'Area', field: :neighborhood }
      ],
      'Muni::Records::PoliceLogEntry'       => [
        { label: 'Category', field: :crime_category },
        { label: 'Location', field: :neighborhood },
        { label: 'Reported', field: :reported_at, format: :short_date }
      ],
      'Muni::Records::CrimeReport'          => [
        { label: 'Category', field: :crime_category },
        { label: 'Neighborhood', field: :neighborhood },
        { label: 'Reported', field: :reported_at, format: :short_date }
      ],
      'Muni::Records::DispatchCall'         => [
        { label: 'Agency', field: :agency },
        { label: 'Group', field: :incident_group },
        { label: 'Received', field: :received_at, format: :short_date }
      ],
      'Muni::Records::CpdCrash'             => [
        { label: 'Status', synthetic: :crash_status, tone: :status },
        { label: 'Location', field: :location_description }
      ],
      'Muni::Records::TrafficVolumeDaily'   => [
        { label: 'Class', field: :vehicle_class },
        { label: 'Count', field: :count },
        { label: 'Observed', field: :observed_at, format: :short_date }
      ],
      'Muni::Records::BicycleCount'         => [
        { label: 'Count', field: :count },
        { label: 'Location', field: :count_location },
        { label: 'Observed', field: :observed_at, format: :short_date }
      ],
      'Muni::Records::PedestrianCountDaily' => [
        { label: 'Count', field: :count },
        { label: 'Intersection', field: :intersection },
        { label: 'Observed', field: :observed_at, format: :short_date }
      ],
      'Muni::Records::BuildingPermit'       => [
        { label: 'Status', field: :status, tone: :status },
        { label: 'Value', field: :declared_valuation, format: :money },
        { label: 'Issued', field: :issued_at, format: :short_date }
      ],
      'Muni::Records::Crash'                => [
        { label: 'Status', synthetic: :crash_status, tone: :status },
        { label: 'Location', field: :location_description }
      ],
      'Muni::Records::Tree'                 => [
        { label: 'Condition', field: :condition, tone: :status },
        { label: 'Diameter', field: :diameter_in, format: :diameter },
        { label: 'Scientific', field: :species_scientific, require: :scientific_name }
      ],
      'Muni::Records::Park'                 => [
        { label: 'Kind', field: :park_type },
        { label: 'Owner', field: :owner },
        { label: 'Acres', field: :acres }
      ],
      'Muni::Records::FoodTruck'            => [
        { label: 'Day', field: :weekday },
        { label: 'Hours', field: :hours },
        { label: 'Issued', field: :issued_at, format: :short_date }
      ],
      'Muni::Records::MeteredParkingSpace'  => [
        { label: 'Status', field: :meter_status, tone: :status },
        { label: 'Max stay', field: :max_time_label },
        { label: 'Rate', field: :rate_label },
        { label: 'Hours', field: :operation_window }
      ],
      'Muni::Records::DigestItem'           => [
        { label: 'Starts', field: :event_start_at, format: :short_date },
        { label: 'Location', field: :location_name },
        { label: 'Category', field: :category },
        { label: 'Source', field: :source_name }
      ]
    }.freeze

    module_function

    def title(row)
      pick(row, TITLE_FIELDS[row.class.name] || DEFAULT_TITLE)
    end

    def subtitle(row)
      pick(row, SUBTITLE_FIELDS[row.class.name] || DEFAULT_SUBTITLE)
    end

    def pick(row, fields)
      h = row.is_a?(Hash) ? row : row.to_h
      fields.each do |f|
        v = h[f]
        next if v.nil? || v.to_s.strip.empty?

        return v.is_a?(Time) ? v.utc.iso8601 : v
      end
      h[:external_id] || h['external_id'] || ''
    end

    def contract
      {
        title_fields:            stringify_contract(TITLE_FIELDS),
        subtitle_fields:         stringify_contract(SUBTITLE_FIELDS),
        meta_fields:             stringify_contract(META_FIELDS),
        field_labels:            stringify_keys(FIELD_LABELS),
        default_title_fields:    DEFAULT_TITLE.map(&:to_s),
        default_subtitle_fields: DEFAULT_SUBTITLE.map(&:to_s)
      }
    end

    def stringify_contract(contract_hash)
      contract_hash.to_h do |klass, value|
        [short_class_name(klass), stringify_value(value)]
      end
    end

    def stringify_value(value)
      case value
      when Array
        value.map { |item| stringify_value(item) }
      when Hash
        stringify_keys(value)
      when Symbol
        value.to_s
      else
        value
      end
    end

    def stringify_keys(hash)
      hash.to_h { |key, value| [key.to_s, stringify_value(value)] }
    end

    def short_class_name(name)
      name.to_s.split('::').last
    end
  end
end
