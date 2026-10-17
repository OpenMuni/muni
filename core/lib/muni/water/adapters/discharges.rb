require 'nokogiri'

module Muni
  module Water
    module Adapters
      class Discharges < Base
        private

        def event(row, operator:)
          date = event_date(row.fetch('date'))
          outfall = row.fetch('outfall').scan(/(?:CAM|MWR|BOS|SOM)\d{3}[A-Z]?/).uniq.join('/')
          raise Error, 'Unresolved outfall identifier' if outfall.empty?

          identity = [outfall, date.iso8601, row['start'], row['stop']].join('/')
          payload = event_payload(row, operator, date)
          location(id: outfall, name: outfall, kind: 'outfall', operator: operator,
                   reach_id: Catalog::OUTFALL_REACHES[outfall],
                   receiving_water: row['water'],
                   municipalities: operator == 'City of Cambridge' ? ['cambridge'] : HALLS)
          record(id: identity, kind: 'discharge', location_id: outfall,
                 reach_id: Catalog::OUTFALL_REACHES[outfall],
                 observed_at: payload.delete(:starts_at) || Clock.eastern(date),
                 original_timezone: 'America/New_York', status: payload.delete(:status), raw: row,
                 parameter: 'discharge_volume', value: payload[:event_volume], unit: 'million gallons',
                 payload: payload)
        rescue Error, ArgumentError => e
          review_event(row, operator, date, outfall, identity, e)
        end

        def review_event(row, operator, date, outfall, identity, error)
          payload = volume_payload(row).merge(
            operator: operator, review_reason: error.message, event_date: date&.iso8601 || row['date'],
            receiving_water: row['water'], affected_area: row['area'], rainfall: row['rainfall'],
            notice_urls: row['notice_urls'], time_precision: 'date', countable: false
          )
          record(id: identity || Water.hash(row), kind: 'discharge', location_id: outfall || row['outfall'],
                 reach_id: Catalog::OUTFALL_REACHES[outfall], observed_at: date && Clock.eastern(date), raw: row,
                 status: 'needs_review', original_timezone: 'America/New_York', payload: payload)
        end

        def event_date(value)
          token = value.to_s[%r{\d{1,2}[./-]\d{1,2}[./-]\d{4}}]
          raise Error, 'Unresolved event date' unless token

          Date.strptime(token.tr('./', '--'), '%m-%d-%Y')
        end

        def event_payload(row, operator, date)
          review = event_review(row)
          starts, stops = event_times(row, date, withheld: !review[:countable])
          { operator: operator, receiving_water: row['water'], affected_area: row['area'], event_date: date.iso8601,
            starts_at: starts, ends_at: stops&.iso8601, reported_duration: row['duration'],
            time_precision: starts ? 'time' : 'date',
            rainfall: row['rainfall'], notice_urls: row['notice_urls'],
            identity_policy: 'Publisher identity or uniquely shared notice document; same-day matches require review.' }
            .merge(review).merge(volume_payload(row))
        end

        def event_review(row)
          text = row.values.join(' ')
          if text.match?(/retracted|no activation/i)
            return { status: 'retracted', countable: false, review_reason: nil }
          end

          reason = if text.match?(/retraction/i)
                     'Linked correction requires event-specific review.'
                   elsif ambiguous_times?(row)
                     'Source retains multiple event times; revision order is unresolved.'
                   end
          { status: reason ? 'needs_review' : 'published', countable: reason.nil?, review_reason: reason }
        end

        def event_times(row, date, withheld:)
          return [nil, nil] if withheld
          raise Error, 'Source retains multiple event times; revision order is unresolved.' if ambiguous_times?(row)

          starts = event_time(row['start'], date)
          stops = event_time(row['stop'], date)
          stops = event_time(row['stop'], date + 1) if starts && stops && stops < starts
          raise Error, 'End time precedes start time' if starts && stops && stops < starts

          [starts, stops]
        end

        def ambiguous_times?(row)
          %w[start stop].any? { |key| row[key].to_s.match?(/\([^)]*\d{1,2}:\d{2}/) }
        end

        def volume_payload(row)
          volume = row['volume'].to_s
          average = row['average'] || volume[/[^|]*average[^|]*/i]
          measured = volume.split('|').grep_v(/average|^\s*\(/i).first.to_s
          { event_volume: number(measured[/\A\s*(\d+(?:\.\d+)?)/, 1]), volume_text: volume,
            volume_qualifier: measured.include?('<') ? '<' : nil, historical_average: average,
            volume_limit: number(measured[/\A\s*<\s*(\d+(?:\.\d+)?)/, 1]),
            treatment_status: volume.match?(/\btreated\b/i) ? 'treated' : 'not specified by source' }
        end

        def event_time(value, date)
          text = value.to_s.strip.gsub(/\b([ap])\.?m\.?/i, '\1m')
          return nil if text.empty? || text.match?(%r{n/a|ongoing|pending}i)

          date = event_date(text) if text.match?(%r{\d{1,2}[/-]\d{1,2}[/-]\d{4}})
          clock = text[/\d{1,2}:\d{2}(?::\d{2})?\s*(?:am|pm)?/i]
          raise Error, 'Unresolved event time' unless clock

          Clock.eastern(date.to_s, clock)
        end
      end

      class MwraCso < Discharges
        def collect
          body = client.get(url)
          return [] unless body

          csv(body, required: ['CSO Number', 'Outfall Location', 'Start Time', 'Volume (million gallons)'])
            .filter_map do |row|
            next unless [row['Outfall Location'], row['Potentially Affected Area']].join(' ').match?(/charles/i)

            event({ 'date' => row['Start Time'], 'outfall' => row['CSO Number'], 'water' => 'Charles River',
                    'area' => row['Potentially Affected Area'], 'start' => row['Start Time'],
                      'stop' => row['Stop Time'],
                    'duration' => row['Duration'], 'volume' => row['Volume (million gallons)'],
                    'average' => row['Volume 3-Year Average (million gallons)'],
                    'rainfall' => row['Event Rainfall (inches)'], 'source_row' => row.to_h }, operator: 'MWRA')
          end
        end
      end

      class CambridgeCso < Discharges
        # Verified against the publisher's one-page correction during the audit.
        # Corrections are explicit, scoped evidence, not URL-keyword inference.
        CORRECTION_URL = 'https://www.cambridgema.gov/-/media/Files/publicworksdepartment/' \
                         'stormwatermanagement/alertnotice/csonotifications/' \
                         '20230803csoretractionforcam005andomissionofcam017activation.pdf'.freeze
        CORRECTION = {
          source_url: CORRECTION_URL, page: 1, issued_at: '2023-08-03T11:08:31-04:00',
          sha256: '5827b2e5379547b303dd5dd232dab43680de31b9dcb088ce06c3ad7aa434cd64',
          reviewed_on: '2026-10-16', event_date: '2023-07-29',
          interpretation: 'Publisher retracts CAM005 and confirms an omitted CAM017 activation ' \
                          'due to meter reporting issues.'
        }.freeze

        def collect
          body, fetched_at = parent_response

          tables = Nokogiri::HTML(body).css('table').select { |table| table.text.include?('CSO Number') }
          raise Error, 'Cambridge discharge table schema changed' if tables.empty?

          records = tables.flat_map do |table|
            table.css('tr').filter_map { |table_row| table_event(table_row) }
          end
          records.each { |row| row[:fetched_at] = fetched_at }
          apply_verified_correction(records, fetched_at: fetched_at)
        end

        private

        def parent_response
          body = client.get(url)
          return [body, retrieval_time] if body

          retained = client.retained_response(url)
          return [retained[:body], retained[:retrieved_at]] if retained

          [client.fresh_get(url), retrieval_time]
        end

        def table_event(table_row)
          cells = table_row.css('td')
          return if cells.length < 9 || cells[0].text.include?('Date')
          return unless cells[2].text.match?(/charles/i)

          values = cells.map { |cell| cell.css('p').empty? ? cell.text.strip : cell.css('p').map(&:text).join(' | ') }
          keys = %w[date outfall water area start stop duration volume rainfall]
          row = keys.zip(values.first(9)).to_h
          row['notice_urls'] = table_row.css('a[href]').map { |a| URI.join(url, a['href']).to_s }
          row['notice_links'] = table_row.css('a[href]').map do |a|
            { 'url' => URI.join(url, a['href']).to_s, 'label' => a.text.strip }
          end
          event(row, operator: 'City of Cambridge')
        end

        def apply_verified_correction(records, fetched_at:)
          linked = records.select { |row| Array(row.dig(:raw, 'notice_urls')).include?(CORRECTION_URL) }
          return records if linked.empty?

          bytes = client.document_bytes(CORRECTION_URL)
          fetched_at = correction_receipt(fetched_at)
          digest = Digest::SHA256.hexdigest(bytes.b)
          if digest != CORRECTION[:sha256]
            (retained_corrections(records) + linked).each do |row|
              unverified_document(row, digest, fetched_at: fetched_at)
            end
            return records
          end

          %w[CAM005 CAM017].each do |outfall|
            targets = correction_targets(records, outfall)
            targets.each { |target| correct_event(target, unique: targets.length == 1, fetched_at: fetched_at) }
          end
          records
        end

        def correction_receipt(parent_fetched_at)
          response = client.responses.reverse.find { |row| row[:url] == CORRECTION_URL }
          response ||= client.retained_response(CORRECTION_URL)
          # A correction depends on both bodies. Retained bytes keep their original
          # receipt times; neither a 304 check nor an old derived row makes them new.
          [Water.time(parent_fetched_at), Water.time(response && response[:retrieved_at])].compact.max
        end

        def retained_corrections(records)
          ids = records.map { |row| row[:external_id] }
          previous = Storage.evidence.where(source_slug: slug, kind: 'discharge', location_id: %w[CAM005 CAM017])
                            .all.map { |row| Storage.decode(row).merge('fetched_at' => row[:fetched_at]) }
          previous.filter_map do |row|
            next if ids.include?(row['external_id'])
            next unless Array(row.dig('payload', 'corrections')).any? { |item| item['source_url'] == CORRECTION_URL }

            record = row.transform_keys(&:to_sym)
            record[:payload] = record[:payload].transform_keys(&:to_sym)
            records << record
            record
          end
        end

        def unverified_document(row, digest, fetched_at:)
          row[:fetched_at] = fetched_at
          row[:status] = 'needs_review'
          row[:payload].merge!(
            countable: false, review_reason: 'Linked correction changed; interpretation requires review.',
            correction_verification: { source_url: CORRECTION_URL, sha256: digest,
                                      expected_sha256: CORRECTION[:sha256] }
          )
        end

        def correction_targets(records, outfall)
          targets = records.select do |row|
            row[:location_id] == outfall && row.dig(:payload, :event_date) == CORRECTION[:event_date]
          end
          if targets.empty? && outfall == 'CAM017'
            omission = omitted_event
            records << omission
            targets = [omission]
          end
          targets
        end

        def omitted_event
          omission = event({ 'date' => '07.29.2023', 'outfall' => 'CAM017', 'water' => 'Charles River',
            'start' => 'N/A', 'stop' => 'N/A', 'volume' => '', 'notice_urls' => [CORRECTION_URL],
            'source_document' => CORRECTION }, operator: 'City of Cambridge')
          omission[:external_id] = Water.hash([slug, CORRECTION_URL, 'CAM017', CORRECTION[:event_date]])
          omission[:payload][:source_record_id] = "#{CORRECTION_URL}#CAM017-2023-07-29"
          omission
        end

        def correct_event(target, unique:, fetched_at:)
          target[:fetched_at] = fetched_at
          retract = target[:location_id] == 'CAM005'
          target[:payload][:corrections] = [CORRECTION.merge(action: retract ? 'retract' : 'confirm_omission')]
          if !unique
            target[:status] = 'needs_review'
            target[:payload].merge!(countable: false, review_reason: 'Correction has multiple possible event targets.')
          elsif retract
            target[:status] = 'retracted'
            target[:payload].merge!(countable:     false,
                                    review_reason: 'Publisher confirms no CAM005 activation occurred.')
          elsif target.dig(:payload, :review_reason) == 'Linked correction requires event-specific review.'
            confirm_omission(target)
          end
        end

        def confirm_omission(target)
          starts, stops = event_times(target[:raw], Date.iso8601(CORRECTION[:event_date]), withheld: false)
          target[:observed_at] = starts if starts
          target[:status] = 'published'
          target[:payload].merge!(countable: true, review_reason: nil, ends_at: stops&.iso8601,
                                  time_precision: starts ? 'time' : 'date')
        rescue Error, ArgumentError => e
          target[:status] = 'needs_review'
          target[:payload].merge!(countable: false, review_reason: e.message)
        end
      end
    end
  end
end
