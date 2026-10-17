module Muni
  module Water
    module Adapters
      class Wqp < Base
        def collect
          load_stations
          selection = Catalog::STATIONS.keys.map { |id| "CRWA-#{id}" }.join(';')
          full = full_reconciliation?(selection)
          params = result_parameters(selection, full)
          body = client.get("#{url}/Result/search", params, conditional: false)
          rows = csv(body, required: %w[Location_Identifier Activity_StartDate Result_MeasureIdentifier Result_Measure])
          records = rows.map { |row| sample(row.to_h) }
          checkpoint['reconciled_month'] = @now.strftime('%Y-%m') if full
          checkpoint['station_selection'] = selection
          checkpoint['normalization_version'] = Normalization::VERSION
          returned = records.map { |row| row[:location_id] }.uniq
          @metadata = { publication_mode: 'laboratory archive', expected_interval: nil, full_reconciliation: full,
                        selected_locations: selection.split(';'), returned_locations: returned,
                        locations_without_results: selection.split(';') - returned }
          records
        end

        private

        def full_reconciliation?(selection)
          checkpoint['reconciled_month'] != @now.strftime('%Y-%m') ||
            checkpoint['station_selection'] != selection ||
            checkpoint['normalization_version'] != Normalization::VERSION
        end

        def result_parameters(selection, full)
          params = { organization: 'CRWA', siteid: selection,
                     characteristicName: 'Escherichia coli', mimeType: 'csv', dataProfile: 'fullPhysChem' }
          snapshot = client.respond_to?(:snapshot_time) ? client.snapshot_time : @now
          params[:startDateLo] = (snapshot.to_date - 400).strftime('%m-%d-%Y') unless full
          params
        end

        def load_stations
          body = client.get("#{url}/Station/search", { organization: 'CRWA', mimeType: 'csv' }, conditional: false)
          csv(body, required: %w[Location_Identifier Location_Name Location_Latitude Location_Longitude]).each do |row|
            short = row['Location_Identifier'].delete_prefix('CRWA-')
            next unless Catalog::STATIONS.key?(short)

            location(id: row['Location_Identifier'], name: row['Location_Name'], kind: 'laboratory',
                     lon: row['Location_Longitude'], lat: row['Location_Latitude'], reach_id: Catalog::STATIONS[short],
                     coordinate_datum: row['Location_HorzCoordReferenceSystemDatum'],
                     note: 'Station-to-reach association is contextual; the sample measures only this station.')
          end
        end

        def sample(row)
          station = row.fetch('Location_Identifier')
          zone = row['Activity_StartTimeZone']
          sample_date = row.fetch('Activity_StartDate')
          sample_time = row['Activity_StartTime'].to_s.empty? ? '00:00' : row['Activity_StartTime']
          observed = Clock.eastern(sample_date, sample_time, zone: zone)
          attributes = record(id: row.fetch('Result_MeasureIdentifier'), kind: 'laboratory', location_id: station,
                              reach_id: Catalog::STATIONS[station.delete_prefix('CRWA-')], observed_at: observed,
                              value: number(row['Result_Measure']), unit: row['Result_MeasureUnit'], parameter: 'ecoli',
                              original_timezone: zone, method: row['ResultAnalyticalMethod_Name'],
                              segment: row['ResultAnalyticalMethod_Identifier'],
                              status: row['Result_MeasureStatusIdentifier'], raw: row, payload: sample_payload(row))
          Normalization.call(attributes)
        rescue Error, ArgumentError => e
          record(id: row.fetch('Result_MeasureIdentifier'), kind: 'laboratory', location_id: station, raw: row,
                 status: 'needs_review', payload: { review_reason: e.message, sample_date: row['Activity_StartDate'] })
        end

        def sample_payload(row)
          type = row['Activity_TypeCode']
          { sample_type: type, routine_sample: type.to_s.empty? ? nil : type == 'Sample-Routine',
            qualifier: row['Result_MeasureQualifierCode'], detection_condition: row['Result_ResultDetectionCondition'],
            detection_limit: row['DetectionLimit_MeasureA'], detection_unit: row['DetectionLimit_MeasureUnitA'],
            activity_id: row['Activity_ActivityIdentifier'], laboratory: row['LabInfo_Name'],
            time_precision: row['Activity_StartTime'].to_s.empty? ? 'date' : 'time',
            observed_date: row['Activity_StartDate'],
            original_value: row['Result_Measure'], original_unit: row['Result_MeasureUnit'] }
        end
      end

      class CrwaLaboratory < Base
        class EditionChanged < Error
          def retryable? = true
          def retry_at = nil
        end

        def collect
          ids = Catalog::STATIONS.keys.map { |id| "'#{id}'" }.join(',')
          params = { f: 'json',
            where: "Site_ID IN (#{ids}) AND Component_Name = 'Escherichia coli'", outFields: '*',
                     orderByFields: 'FID', returnGeometry: 'false' }
          signature = Water.hash([url, params, Normalization::VERSION])
          edition = starting_edition
          if unchanged_archive?(edition, signature)
            @metadata = checkpoint.fetch('metadata', {})
                                  .merge('full_reconciliation' => false, 'unchanged_source' => true)
            return []
          end

          records, edition = stable_collection(params, edition)
          checkpoint.merge!('archive_edition' => edition, 'archive_signature' => signature,
                            'reconciled_month' => @now.strftime('%Y-%m'))
          @metadata = { publication_mode: 'laboratory archive', full_reconciliation: true, unchanged_source: false,
                        last_full_reconciliation_at: @now.iso8601,
                        source_last_edited_at: edition && Time.at(edition / 1000.0).utc.iso8601 }
          records
        end

        private

        def stable_collection(params, edition)
          3.times do |attempt|
            records = remote_rows("#{url}/query", params).map do |feature|
              sample(feature.fetch('attributes'), fetched_at: feature['_muni_retrieved_at'])
            end
            after = layer_edition
            return [records, after] if edition == after

            client.discard_pending! if client.respond_to?(:discard_pending!)
            raise EditionChanged, 'CRWA archive changed during pagination; no partial edition published' if attempt == 2

            edition = layer_edition
          end
        end

        def starting_edition
          pending = client.pending_body(url, { f: 'json' }) if client.respond_to?(:pending_body)
          edition = layer_edition
          return edition unless pending && (edition.nil? || parse_edition(pending) != edition)

          client.discard_pending!
          layer_edition
        end

        def layer_edition
          body = if client.respond_to?(:fresh_get)
                   client.fresh_get(url, { f: 'json' })
                 else
                   client.get(url, { f: 'json' }, conditional: false)
                 end
          parse_edition(body)
        end

        def parse_edition(body)
          data = JSON.parse(body)
          info = data['editingInfo'] if data.is_a?(Hash)
          stamp = info['dataLastEditDate'] || info['lastEditDate'] if info.is_a?(Hash)
          stamp if stamp.is_a?(Integer) && stamp.positive?
        rescue JSON::ParserError, TypeError
          nil
        end

        def unchanged_archive?(edition, signature)
          edition && checkpoint['archive_edition'] == edition && checkpoint['archive_signature'] == signature &&
            checkpoint['reconciled_month'] == @now.strftime('%Y-%m')
        end

        def sample(row, fetched_at: nil)
          station = "CRWA-#{row.fetch('Site_ID')}"
          observed = Time.at(row.fetch('Date_Collected') / 1000.0).utc
          attributes = record(id: row['GlobalID'] || row.fetch('FID'), kind: 'laboratory', location_id: station,
                              reach_id: Catalog::STATIONS[row['Site_ID']], observed_at: observed, parameter: 'ecoli',
                              value: number(row.fetch('Reporting_Result')), unit: row.fetch('Unit_Abbreviation'),
                              original_timezone: 'UTC', method: nil, raw: row, fetched_at: fetched_at || retrieval_time,
                              payload: { time_precision: 'date',
                                publication_overlap: 'May also appear in WQP; not pooled in statistics.',
                                         routine_sample: nil, original_value: row['Reporting_Result'],
                                         original_unit: row['Unit_Abbreviation'] })
          Normalization.call(attributes)
        end
      end
    end
  end
end
