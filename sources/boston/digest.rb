require 'digest'
require_relative '_shared'

module Boston
  class ConstructionHighlights < Muni::Source
    include SharedCkan

    PACKAGE = 'public-works-active-work-zones'.freeze

    source :construction_highlights,
           hall: 'boston', emits: Muni::Records::DigestItem, base_url: SharedCkan::BASE_URL,
           digest_role: :construction, cadence: '1d', inventory: :replace,
           catalog: { package: PACKAGE }

    def each_record(limit: nil, offset: 0, **)
      return enum_for(__method__, limit: limit, offset: offset, **) unless block_given?

      each_resource_row(package_id: PACKAGE, fields: %w[Permit Status Street], order: '"Permit" ASC',
                        limit: limit, offset: offset, changed_only: limit.nil?) { |row| yield normalize(row) }
    end

    def normalize(row)
      id = clean(row['Permit'] || row['_id']) || Digest::SHA256.hexdigest(row.to_s)[0, 20]
      street = clean(row['Street'] || row['Intersection'])
      title = [row['Project_Category'], street].filter_map { |value| clean(value) }.join(' — ')
      emit(
        external_id: "work-zone:#{id}", hall: 'boston', source_slug: self.class.slug,
        source_name: 'Boston Public Works', source_type: 'official_record', item_type: 'construction',
        section_hint: 'construction', title: title.empty? ? "Work zone #{id}" : title,
        summary: clean(row['Construction_Notes'] || row['Work_Schedule']), category: clean(row['Status']),
        url: dataset_url(PACKAGE), event_end_at: time(row['Estimated_Completion_Date'] || row['ExpirationDate']),
        updated_at: Time.now.utc, fetched_at: Time.now.utc, location_name: street,
        neighborhood: clean(row['Neighborhood']), tags: [clean(row['Permittee']), clean(row['Contractor'])].compact,
        dedupe_key: "boston-work-zone:#{id}", metadata: row
      )
    end
  end

  class CityCalendar < Muni::Source
    include SharedCkan

    PACKAGE = 'special-event-license-applications'.freeze
    HISTORY_DAYS = 90

    source :city_calendar,
           hall: 'boston', emits: Muni::Records::DigestItem, base_url: SharedCkan::BASE_URL,
           domains: [:events], categories: %i[events], digest_role: :events,
           cadence: '1d', retention_days: HISTORY_DAYS, catalog: { package: PACKAGE }

    def each_record(since: nil, limit: nil, **)
      return enum_for(__method__, since: since, limit: limit, **) unless block_given?

      cutoff = [since, Time.now.utc - (HISTORY_DAYS * 86_400)].compact.max
      each_resource_row(package_id: PACKAGE, fields: ['App Number', 'Start Date and Time'],
                        where: %("End Date and Time" >= '#{sql_time(cutoff)}'),
                        order: '"Start Date and Time" ASC', limit: limit) { |row| yield normalize(row) }
    end

    def cursor_time(record) = record.updated_at || record.event_start_at

    def normalize(row)
      id = clean(row['App Number'] || row['_id']) || Digest::SHA256.hexdigest(row.to_s)[0, 20]
      street = [row['Street Number'], row['Street Name'], row['Street Suffix']]
               .filter_map { |value| clean(value) }.join(' ')
      location = clean(row['Location Description']) || clean(street)
      emit(
        external_id: "special-event:#{id}", hall: 'boston', source_slug: self.class.slug,
        source_name: 'Boston Special Events', source_type: 'event_listing', item_type: 'event',
        section_hint: 'events', title: clean(row['App Name']) || "Special event #{id}",
        summary: clean(row['Status']), category: 'Special event', url: dataset_url(PACKAGE),
        published_at: time(row['Issued Date'] || row['Application Date']),
        event_start_at: time(row['Start Date and Time']), event_end_at: time(row['End Date and Time']),
        updated_at: time(row['Issued Date'] || row['Application Date']), fetched_at: Time.now.utc,
        location_name: location, dedupe_key: "boston-special-event:#{id}", metadata: row
      )
    end
  end
end
