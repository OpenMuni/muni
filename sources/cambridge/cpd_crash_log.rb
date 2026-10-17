require_relative '_shared'
require_relative 'location_resolver'
require 'digest'

module Cambridge
  class CpdCrashLog < Muni::Source
    include Cambridge::SharedSoda

    source :cpd_crash_log,
           hall:     'cambridge',
           emits:    Muni::Records::CpdCrash,
           base_url: SharedSoda::BASE_URL,
           auth:     :app_token

    RESOURCE = ENV.fetch('CAMBRIDGE_CPD_CRASH_LOG_RESOURCE', 'h6fp-bp8s').freeze

    def pull(since: nil, limit: 1_000)
      cursor = bounded_since(since, days: 90)
      where = "datetime >= '#{soql_since(cursor)}'"
      rows = socrata.query(resource: RESOURCE, where: where, order: 'datetime DESC', limit: limit)
      rows.map { |r| normalize(r) }
    end

    def cursor_time(record)
      record.occurred_at
    end

    private

    def normalize(row)
      emit(
        external_id:          external_id(row),
        hall:                 'cambridge',
        location_description: location_description(row),
        neighborhood:         clean_string(row['neighborhood']),
        motorists:            integer(row['motorists']),
        cyclists:             integer(row['cyclists']),
        pedestrians:          integer(row['pedestrians']),
        injuries:             integer(row['injuries']),
        hospitalizations:     integer(row['hospitalizations']),
        injury:               integer(row['injuries']).positive? || integer(row['hospitalizations']).positive?,
        cyclist:              integer(row['cyclists']).positive?,
        pedestrian:           integer(row['pedestrians']).positive?,
        location:             point(row),
        occurred_at:          Muni::Helpers::Normalize.parse_time(row['datetime']),
        source_url:           dataset_url
      )
    end

    def external_id(row)
      fields = row.values_at('datetime', 'intersection_street1', 'intersection_street2',
                             'address_number', 'address_street', 'motorists', 'cyclists',
                             'pedestrians', 'injuries', 'hospitalizations')
      "cpd-crash/#{Digest::SHA256.hexdigest(fields.join('|'))[0, 20]}"
    end

    def location_description(row)
      intersection = [row['intersection_street1'], row['intersection_street2']]
                     .map { |v| clean_string(v) }.compact
      return intersection.join(' / ') unless intersection.empty?

      [row['address_number'], row['address_street']].map { |v| clean_string(v) }.compact.join(' / ')
    end

    def point(row)
      label = location_description(row)
      return nil if label.to_s.empty?

      resolver = @opts[:location_resolver] || (@location_resolver ||= Cambridge::LocationResolver.new)
      resolver.respond_to?(:call) ? resolver.call(label) : nil
    end

    def integer(value)
      value.to_f.to_i
    end

    def dataset_url
      "#{SharedSoda::BASE_URL}/d/#{RESOURCE}"
    end
  end
end
