require_relative '_shared'

module Boston
  module PermitNormalization
    PACKAGE = 'approved-building-permits'.freeze
    RETENTION_DAYS = 365

    def permit_id(row)
      clean(row['permitnumber'] || row['_id']) || raise(ArgumentError, 'permit row has no ID')
    end

    def permit_address(row)
      [row['address'], row['city'], row['state'], row['zip']].filter_map { |value| clean(value) }.join(', ')
    end

    def permit_point(row)
      row_point(row, lon: %w[x_longitude gpsx], lat: %w[y_latitude gpsy])
    end
  end

  class BuildingPermits < Muni::Source
    include SharedCkan
    include PermitNormalization

    source :building_permits,
           hall: 'boston', emits: Muni::Records::BuildingPermit, base_url: SharedCkan::BASE_URL,
           domains: [:permits], categories: %i[permits], cadence: '1d', retention_days: 365,
           criticality: :critical, catalog: { package: PermitNormalization::PACKAGE }

    def each_record(since: nil, limit: nil, **)
      return enum_for(__method__, since: since, limit: limit, **) unless block_given?

      cutoff = [since, Time.now.utc - (PermitNormalization::RETENTION_DAYS * 86_400)].compact.max
      each_resource_row(package_id: PermitNormalization::PACKAGE, fields: %w[permitnumber issued_date],
                        where: %("issued_date" >= '#{sql_time(cutoff)}'), order: '"issued_date" DESC',
                        limit: limit) { |row| yield normalize(row) }
    end

    def cursor_time(record) = record.issued_at || record.applied_at

    def normalize(row)
      emit(
        external_id: permit_id(row), hall: 'boston', permit_type: clean(row['permittypedescr'] || row['worktype']),
        status: clean(row['status']), description: clean(row['description'] || row['comments']),
        address: permit_address(row), location: permit_point(row),
        declared_valuation: money(row['declared_valuation']), issued_at: time(row['issued_date']),
        property_use: clean(row['occupancytype']), mbl: clean(row['parcel_id'] || row['property_id']),
        source_url: dataset_url(PermitNormalization::PACKAGE)
      )
    end
  end

  class NewConstructionPermits < Muni::Source
    include SharedCkan
    include PermitNormalization

    source :new_construction_permits,
           hall: 'boston', emits: Muni::Records::NewConstructionPermit, base_url: SharedCkan::BASE_URL,
           domains: [:new_construction], categories: %i[developments], cadence: '1d', retention_days: 365,
           catalog: { package: PermitNormalization::PACKAGE, filter: "permittypedescr = 'Erect/New Construction'" }

    def each_record(since: nil, limit: nil, **)
      return enum_for(__method__, since: since, limit: limit, **) unless block_given?

      cutoff = [since, Time.now.utc - (PermitNormalization::RETENTION_DAYS * 86_400)].compact.max
      where = %("issued_date" >= '#{sql_time(cutoff)}' AND "permittypedescr" = 'Erect/New Construction')
      each_resource_row(package_id: PermitNormalization::PACKAGE, fields: %w[permitnumber permittypedescr],
                        where: where, order: '"issued_date" DESC', limit: limit) do |row|
        yield normalize(row)
      end
    end

    def cursor_time(record) = record.issued_at || record.applied_at

    def normalize(row)
      emit(
        external_id: permit_id(row), hall: 'boston', status: clean(row['status']),
        address: permit_address(row), location: permit_point(row), proposed_use: clean(row['occupancytype']),
        construction_type: clean(row['worktype'] || row['permittypedescr']),
        gross_square_footage: money(row['sq_feet']), declared_valuation: money(row['declared_valuation']),
        description: clean(row['description'] || row['comments']), mbl: clean(row['parcel_id'] || row['property_id']),
        issued_at: time(row['issued_date']), source_url: dataset_url(PermitNormalization::PACKAGE)
      )
    end
  end

  class DevelopmentProjects < Muni::Source
    include SharedCkan

    PACKAGE = 'article80-development-projects'.freeze

    source :development_projects,
           hall: 'boston', emits: Muni::Records::DevelopmentProject, base_url: SharedCkan::BASE_URL,
           domains: [:developments], categories: %i[developments], cadence: '1d', inventory: :replace,
           catalog: { package: PACKAGE }

    def each_record(limit: nil, offset: 0, **)
      return enum_for(__method__, limit: limit, offset: offset, **) unless block_given?

      each_resource_row(package_id: PACKAGE, fields: %w[project_id project__project_name],
                        order: '"project_id" ASC', limit: limit, offset: offset,
                        changed_only: limit.nil?) { |row| yield normalize(row) }
    end

    def normalize(row)
      address = [row['project_street_number'], row['project_street_name'], row['project_street_suffix']]
                .filter_map { |value| clean(value) }.join(' ')
      emit(
        external_id: clean(row['project_id'] || row['_id']) || raise(ArgumentError, 'development row has no ID'),
        hall: 'boston', name: clean(row['project__project_name']), status: clean(row['project_status']),
        address: address, location: row_point(row), primary_use: clean(row['project_uses']),
        project_type: clean(row['project__record_type']), residential_units: integer(row['total_residential_units']),
        gross_floor_area: money(row['gross_square_footage']), neighborhood: clean(row['neighborhood']),
        description: clean(row['description']), source_url: clean(row['website_url']) || dataset_url(PACKAGE)
      )
    end
  end

  class ZoningAppeals < Muni::Source
    include SharedCkan

    PACKAGE = 'zoning-board-of-appeal-tracker'.freeze

    source :zoning_appeals,
           hall: 'boston', emits: Muni::Records::ZoningAppeal, base_url: SharedCkan::BASE_URL,
           domains: [:zoning_appeals], categories: %i[zoning_appeals], cadence: '1d', inventory: :replace,
           catalog: { package: PACKAGE, geometry: false }

    def each_record(limit: nil, offset: 0, **)
      return enum_for(__method__, limit: limit, offset: offset, **) unless block_given?

      each_resource_row(package_id: PACKAGE, fields: %w[boa_apno address], order: '"boa_apno" ASC',
                        limit: limit, offset: offset, changed_only: limit.nil?) { |row| yield normalize(row) }
    end

    def normalize(row)
      emit(
        external_id: clean(row['boa_apno'] || row['parent_apno'] || row['_id']) ||
                     raise(ArgumentError, 'zoning row has no ID'),
        hall: 'boston', status: clean(row['status'] || row['decision']), address: clean(row['address']),
        zoning_district: clean(row['zoning_district']), relief: clean(row['appeal_type'] || row['project_description']),
        applied_at: time(row['submitted_date'] || row['received_date']),
        hearing_deadline_at: time(row['hearing_date']), decided_at: time(row['final_decision_date']),
        source_url: dataset_url(PACKAGE)
      )
    end
  end
end
