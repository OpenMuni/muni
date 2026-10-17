require 'digest'
require_relative '_shared'

module Boston
  class MeteredParkingSpaces < Muni::Source
    include SharedCkan

    PACKAGE = 'parking-meters'.freeze

    source :metered_parking_spaces,
           hall: 'boston', emits: Muni::Records::MeteredParkingSpace, base_url: SharedCkan::BASE_URL,
           domains: [:parking], categories: %i[parking], cadence: '1d', inventory: :replace,
           catalog: { package: PACKAGE }

    def each_record(limit: nil, offset: 0, **)
      return enum_for(__method__, limit: limit, offset: offset, **) unless block_given?

      each_resource_row(package_id: PACKAGE, fields: %w[METER_ID PAY_POLICY], order: '"METER_ID" ASC',
                        limit: limit, offset: offset, changed_only: limit.nil?) { |row| yield normalize(row) }
    end

    def normalize(row)
      policy = clean(row['PAY_POLICY'])
      max_minutes = parking_policy_max_minutes(policy)
      base_rate = money(row['BASE_RATE'])
      meter_id = clean(row['METER_ID'] || row['_id']) || raise(ArgumentError, 'meter row has no ID')
      space = clean(row['SPACE_NUMBER'])
      status = meter_status(row)
      emit(
        external_id: [meter_id, space].compact.join(':'), hall: 'boston', space_id: space || meter_id,
        pay_by_phone_zone: clean(row['G_PASSPORT_ZONES'] || row['G_PM_ZONE']),
        max_minutes: max_minutes, max_time_label: max_minutes && "#{max_minutes} min",
        rate_label: base_rate && format('$%.2f base rate', base_rate),
        operation_hours: policy, operation_window: policy&.split(/\s+\$/)&.first,
        rule_status: clean(status), smart_meter: clean(row['HAS_SENSOR'] || row['METER_TYPE']),
        location: row_point(row, lon: %w[LONGITUDE POINT_X], lat: %w[LATITUDE POINT_Y]),
        source_url: dataset_url(PACKAGE)
      )
    end

    private

    def parking_policy_max_minutes(policy)
      return unless policy

      policy.scan(/\s(\d+)\s*(?:,|\z)/).flatten.map(&:to_i).max
    end

    def meter_status(row)
      [row['METER_STATE'], row['SPACE_STATE']].filter_map { |value| clean(value) }.uniq.join(' / ')
    end
  end

  class TreeInventory < Muni::Source
    include SharedCkan

    PACKAGE = 'bprd-trees'.freeze

    source :tree_inventory,
           hall: 'boston', emits: Muni::Records::Tree, base_url: SharedCkan::BASE_URL,
           domains: [:trees], categories: %i[environment trees], cadence: '1d', inventory: :replace,
           catalog: { package: PACKAGE }

    def each_record(limit: nil, offset: 0, **)
      return enum_for(__method__, limit: limit, offset: offset, **) unless block_given?

      each_resource_row(package_id: PACKAGE, fields: %w[id spp_com], order: '"id" ASC', limit: limit,
                        offset: offset, changed_only: limit.nil?) { |row| yield normalize(row) }
    end

    def normalize(row)
      emit(
        external_id: clean(row['id'] || row['_id']) || raise(ArgumentError, 'tree row has no ID'), hall: 'boston',
        species_common: clean(row['spp_com']), species_scientific: clean(row['spp_bot']),
        diameter_in: money(row['dbh']), ownership: 'City of Boston', plant_date: time(row['date_plant']),
        notes: clean(row['park'] || row['site']),
        location: row_point(row, lon: %w[x_longitude POINT_X], lat: %w[y_latitude POINT_Y]),
        source_url: dataset_url(PACKAGE)
      )
    end
  end

  class Parks < Muni::Source
    include SharedCkan

    PACKAGE = 'open-space'.freeze

    source :parks,
           hall: 'boston', emits: Muni::Records::Park, base_url: SharedCkan::BASE_URL,
           domains: [:parks], categories: %i[environment parks], cadence: '1d', inventory: :replace,
           catalog: { package: PACKAGE, geometry: :shape_wkt }

    def each_record(limit: nil, offset: 0, **)
      return enum_for(__method__, limit: limit, offset: offset, **) unless block_given?

      each_resource_row(package_id: PACKAGE, fields: %w[OS_ID SITE_NAME shape_wkt], order: '"OS_ID" ASC',
                        limit: limit, offset: offset, changed_only: limit.nil?) { |row| yield normalize(row) }
    end

    def normalize(row)
      geometry = wkt_geometry(row['shape_wkt'])
      emit(
        external_id: clean(row['OS_ID'] || row['PARK_ID'] || row['_id']) || raise(ArgumentError, 'park row has no ID'),
        hall: 'boston', name: clean(row['SITE_NAME'] || row['ALT_NAME']),
        owner: clean(row['OWNERSHIP'] || row['OS_Own_Jur']), park_type: clean(row['TypeLong'] || row['TYPECODE']),
        acres: money(row['ACRES']), location: Muni::Helpers::Geo.centroid(geometry), geometry: geometry,
        source_url: dataset_url(PACKAGE)
      )
    end
  end

  class FoodTrucks < Muni::Source
    include SharedCkan

    PACKAGE = 'food-truck-schedule'.freeze

    source :food_trucks,
           hall: 'boston', emits: Muni::Records::FoodTruck, base_url: SharedCkan::BASE_URL,
           domains: [:food_trucks], categories: %i[food_trucks], cadence: '1d', inventory: :replace,
           catalog: { package: PACKAGE }

    def each_record(limit: nil, offset: 0, **)
      return enum_for(__method__, limit: limit, offset: offset, **) unless block_given?

      each_resource_row(package_id: PACKAGE, fields: %w[Day Truck Location], order: '"Day" ASC, "Truck" ASC',
                        limit: limit, offset: offset, changed_only: limit.nil?) { |row| yield normalize(row) }
    end

    def normalize(row)
      stable_fields = row.values_at('Day', 'Time', 'Truck', 'Location').join('|')
      identity = clean(row['_id']) || Digest::SHA256.hexdigest(stable_fields)[0, 20]
      emit(
        external_id: "food-truck:#{identity}", hall: 'boston', status: 'Scheduled',
        business_name: clean(row['Management']), truck_name: clean(row['Truck']),
        weekday: clean(row['Day']), hours: clean(row['Hours'] || row['Time']), address: clean(row['Location']),
        location: row_point(row, lon: %w[x POINT_X], lat: %w[y POINT_Y]),
        source_url: clean(row['Link']) || dataset_url(PACKAGE)
      )
    end
  end

  class BicycleCounts < Muni::Source
    include SharedCkan

    PACKAGE = 'streets-daily-bike-counts'.freeze
    RETENTION_DAYS = 1_095

    source :bicycle_counts,
           hall: 'boston', emits: Muni::Records::BicycleCount, base_url: SharedCkan::BASE_URL,
           domains: [:bicycle_counts], cadence: '1d', retention_days: RETENTION_DAYS,
           catalog: { package: PACKAGE }

    def each_record(since: nil, limit: nil, **)
      return enum_for(__method__, since: since, limit: limit, **) unless block_given?

      cutoff = [since, Time.now.utc - (RETENTION_DAYS * 86_400)].compact.max
      each_resource_row(package_id: PACKAGE, fields: %w[count_id date day_bikes],
                        where: %("year" >= '#{cutoff.year}'), order: '"year" DESC, "_id" DESC',
                        limit: limit, changed_only: limit.nil?) { |row| yield normalize(row) }
    end

    def cursor_time(record) = record.observed_at

    def normalize(row)
      date = time(row['date'])
      base = clean(row['count_id'] || row['_id']) || Digest::SHA256.hexdigest(row.to_s)[0, 16]
      emit(
        external_id: "#{base}:#{date&.strftime('%Y-%m-%d') || 'undated'}", hall: 'boston',
        count_location: clean(row['location_name']), count: integer(row['day_bikes']),
        weather: clean(row['weather']), notes: clean(row['notes']), node_number: clean(row['count_id']),
        location: row_point(row, lon: %w[long POINT_X], lat: %w[lat POINT_Y]),
        observed_at: date, source_url: dataset_url(PACKAGE)
      )
    end
  end
end
