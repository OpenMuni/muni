module Muni
  module Water
    module Adapters
      class Buoy < Base
        PARAMETERS = {
          'temp c' => %w[temperature °C], 'spcond (ms/cm)' => %w[conductivity mS/cm],
          'ph' => %w[ph pH], 'do (mg/l)' => %w[dissolved_oxygen mg/L],
          'do (%)' => %w[oxygen_saturation %], 'turbidity (fnu)' => %w[turbidity FNU],
          'chlorophyll (rfu)' => %w[chlorophyll RFU], 'phycocyanin (rfu)' => %w[phycocyanin RFU],
          'est. cyano (cells/ml)' => %w[estimated_cyanobacteria cells/mL],
          'est.chl a (ug/l)' => %w[estimated_chlorophyll_a µg/L]
        }.freeze

        def collect
          body = client.get(url)
          return [] unless body

          parser = Water.hash([VERSION, PARAMETERS, defined?(Normalization::VERSION) && Normalization::VERSION])
          digest = Digest::SHA256.hexdigest(body)
          if checkpoint['buoy_response_digest'] == digest && checkpoint['buoy_row_parser'] == parser
            @metadata = @metadata.merge('unchanged_source' => true, 'changed_source_rows' => 0)
            return []
          end

          table, time_header, first = parsed_table(body)
          season = Date.strptime(first['date'], '%m/%d/%Y').year
          @metadata = { deployment_year: season, first_observation: first['date'], expected_interval: 900 }
          previous = checkpoint['buoy_row_parser'] == parser ? checkpoint.fetch('buoy_row_fingerprints', {}) : {}
          rows, fingerprints = changed_rows([first].chain(table), time_header, previous)
          records = rows.flat_map { |row| measurements(row, time_header, season) }
          checkpoint.merge!('buoy_response_digest' => digest, 'buoy_row_parser' => parser,
                            'buoy_row_fingerprints' => fingerprints)
          @metadata.merge!(source_rows: fingerprints.length, changed_source_rows: rows.length, unchanged_source: false)
          records
        end

        private

        def parsed_table(body)
          source = body.start_with?("\uFEFF") ? body.delete_prefix("\uFEFF") : body
          table = CSV.new(source, headers: true)
          first = table.shift
          raise Error, 'Buoy response contains no observations' unless first

          required = ['date', *PARAMETERS.keys.first(8)]
          raise Error, "Source schema missing: #{required.join(', ')}" unless (required - table.headers).empty?

          time_header = table.headers.find { |header| header&.match?(/\Atime (edt|est)\z/i) }
          raise Error, 'Buoy time column or explicit timezone is missing' unless time_header

          [table, time_header, first]
        rescue CSV::MalformedCSVError
          raise Error, 'Source response is not valid CSV'
        end

        def changed_rows(table, time_header, previous)
          fingerprints = {}
          changed = []
          table.each do |row|
            key = [row.fetch('date'), row.fetch(time_header), time_header].join('/')
            fingerprint = Water.hash(row.to_h)
            if fingerprints.key?(key)
              raise Error, 'Buoy returned conflicting rows for the same timestamp' if fingerprints[key] != fingerprint

              next
            end
            fingerprints[key] = fingerprint
            changed << row.to_h unless previous[key] == fingerprint
          end
          [changed, fingerprints]
        rescue CSV::MalformedCSVError
          raise Error, 'Source response is not valid CSV'
        end

        def measurements(row, time_header, season)
          date = Date.strptime(row.fetch('date'), '%m/%d/%Y')
          zone = time_header.split.last.upcase
          observed = Clock.eastern(date, row.fetch(time_header), zone: zone)
          PARAMETERS.filter_map do |column, (parameter, unit)|
            next unless row.key?(column)

            value = number(row[column])
            derived = parameter.start_with?('estimated_')
            record(id: "#{observed.iso8601}/#{parameter}", kind: derived ? 'derived_sensor' : 'sensor',
                   location_id: 'epa-buoy', reach_id: '5', observed_at: observed, value: value, unit: unit,
                   parameter: parameter, original_timezone: zone,
                   method: derived ? 'EPA source estimate' : 'EPA buoy sensor',
                   segment: "epa-#{season}", status: value ? 'provisional' : 'missing',
                   raw: row.slice('date', time_header, column),
                   payload: { original_value: row[column], original_unit: unit, source_column: column,
                              limitation: 'One sensor location; preliminary, subject to error or revision.' })
          end
        end
      end
    end
  end
end
