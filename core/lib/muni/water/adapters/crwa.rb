module Muni
  module Water
    module Adapters
      class CrwaPredictions < Base
        def collect
          body = client.get(url, { hours: 24 })
          return [] unless body

          data = json(body)
          season = data.fetch('is_boating_season')
          raise Error, 'Invalid boating season flag' unless [true, false].include?(season)

          @metadata = { boating_season: season, model_version: data.fetch('model_version') }
          checkpoint['boating_season'] = season
          data.fetch('model_outputs').flat_map { |reach| predictions(reach, data) }
        end

        private

        def predictions(reach, data)
          reach_id = reach.fetch('reach').to_s
          raise Error, 'Unexpected CRWA reach' unless %w[2 3 4 5].include?(reach_id)

          reach.fetch('predictions').map do |row|
            observed = Time.httpdate(row.fetch('time')).utc
            value = number(row.fetch('prediction'))
            raise Error, 'Invalid CRWA prediction' unless value && [true, false].include?(row['safe'])

            record(id: "#{reach_id}/#{observed.iso8601}", kind: 'prediction', location_id: "reach-#{reach_id}",
                   reach_id: reach_id, observed_at: observed, value: value, unit: 'CFU/100mL', parameter: 'ecoli',
                   original_timezone: 'UTC', segment: data.fetch('model_version'), method: 'CRWA predictive model',
                   raw: row.merge('reach' => reach_id, 'model_version' => data['model_version']),
                   payload: { publisher_boating_flag: row['safe'], model_version: data['model_version'],
                              comparison: if row['safe']
                                            'CRWA boating model: below comparison level'
                                          else
                                            'CRWA boating model: elevated prediction'
                                          end,
                              limitation: 'Prediction only; does not establish swimming safety or advisory absence.' })
          end
        end
      end

      class CrwaBoathouses < Base
        def collect
          body = client.get(url)
          return [] unless body

          rows = json(body).fetch('boathouses')
          raise Error, 'Boathouse response contains no locations' if rows.empty?

          rows.map { |row| state(row) }
        end

        private

        def state(row)
          raise Error, 'Invalid override flag' unless [true, false].include?(row.fetch('overridden'))

          id = "boathouse-#{Water.hash(row.fetch('boathouse'))[0, 16]}"
          location(id: id, name: row['boathouse'], kind: 'boathouse', lon: row.fetch('longitude'),
                   lat: row.fetch('latitude'), reach_id: row.fetch('reach').to_s)
          record(id: id, kind: 'program_state', location_id: id, reach_id: row['reach'].to_s, raw: row,
                 status: row['overridden'] ? 'active' : 'inactive',
                 payload: { name: row['boathouse'], active: row['overridden'], reason: row['reason'],
                            publisher_boating_flag: row['safe'],
                            limitation: 'CRWA program state; source supplies no issuance or expiry.' })
        end
      end
    end
  end
end
