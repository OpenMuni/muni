require 'muni/water/calculation_fence'

module Muni
  module Water
    class Signals
      METHOD_VERSION = 'water-v2.0'.freeze

      def initialize(now: Time.now.utc)
        @now = now
      end

      def recalculate(slug:, dirty: nil, revision_range: nil)
        collection(slug)
        Gaps.new(now: @now, publisher: self).calculate(slug, dirty: dirty)
        revisions(slug, revision_range)
        SensorShifts.new(now: @now, publisher: self).calculate(dirty: dirty) if slug == "#{PREFIX}epa_buoy"
      end

      def collection(slug)
        definition = Catalog.definitions[slug.delete_prefix(PREFIX)]
        return unless definition

        runs = Storage.db[:water_runs].where(source_slug: slug)
        latest = runs.order(Sequel.desc(:id)).first
        return unless latest

        interrupted = latest[:status] == 'failed' || @now - latest[:started_at] > definition[:cadence] * 2
        publish("collection/#{slug}", 'collection_interruption', interrupted ? 'active' : 'resolved',
                source_slug: slug, evidence: { run_id: latest[:id] }, window: { start: latest[:started_at] },
                explanation: interrupted ? 'Collection interrupted; upstream availability unknown.' : 'Checks running.',
                method: 'Failed check or no check within two scheduled intervals.',
                last_check_at: latest[:started_at], error: Muni::Status.public_error(latest[:error]))
      end

      def publish(key, kind, status, payload)
        payload = payload.merge(method_version: METHOD_VERSION, limitations: payload[:limitations] ||
          'A change in published evidence does not establish pollution, a sensor fault, or a health classification.')
        current = Storage.db[:water_signals].where(signal_key: key).first
        previous = current || previous_version(key)
        # Generation time is not evidence. Avoid version churn on identical calculations.
        if previous && previous[:status] == status && comparison(JSON.parse(previous[:payload])) == comparison(payload)
          restore(previous, payload) unless current
          return
        end

        row = { id: Water.hash([key, status, payload, previous && previous[:id]]), signal_key: key, kind: kind,
                status: status, generated_at: @now, payload: Water.json(payload) }
        Muni::Store.with_writer do
          Storage.db.transaction do
            verify_inputs!(kind, payload)
            Storage.db[:water_signal_versions].insert_conflict.insert(row)
            Storage.db[:water_signals].where(signal_key: key).delete
            Storage.db[:water_signals].insert(row)
          end
        end
      end

      private

      def restore(row, payload)
        Muni::Store.with_writer do
          verify_inputs!(row[:kind], payload)
          Storage.db[:water_signals].insert(row)
        end
      end

      def verify_inputs!(kind, payload)
        return unless kind == 'sustained_sensor_shift' && payload.dig(:evidence, :revision_cutoff)

        CalculationFence.verify!(payload[:evidence][:revision_cutoff], [payload[:source_slug]])
      end

      def previous_version(key)
        Storage.db[:water_signal_versions].where(signal_key: key).order(Sequel.desc(Sequel.lit('rowid'))).first
      end

      def comparison(payload)
        value = Water.canonical(payload)
        value['evidence']&.delete('revision_cutoff')
        value['evidence']&.delete('daily_revision_cutoffs')
        value.dig('evidence', 'daily_statistics')&.each_value { |day| day.delete('revision_cutoff') }
        Water.json(value)
      end

      def revisions(slug, revision_range = nil)
        return if revision_range && revision_range.first > revision_range.last

        ids = Storage.evidence.where(source_slug: slug).select(:external_id)
        history = Storage.db[:water_revisions].where(evidence_id: ids).where { version > 1 }
        history = history.where(id: revision_range.first..revision_range.last) if revision_range
        publication = "COALESCE(json_extract(record, '$.payload.change_kind'), '') != 'normalization'"
        history = history.where(Sequel.lit(publication))
        history.each do |revision|
          previous = Storage.db[:water_revisions].where(evidence_id: revision[:evidence_id],
                                                        version:     revision[:version] - 1).first
          before = JSON.parse(previous[:record])
          after = JSON.parse(revision[:record])
          next if before['raw'] == after['raw']

          publish("revision/#{revision[:id]}", 'published_record_changed', 'recorded',
                  source_slug: slug, evidence: { id: revision[:evidence_id], revisions: [previous[:id],
                                                                                         revision[:id]] },
                  window: { detected_at: revision[:detected_at] },
                    method: 'Semantic comparison of retained publications.',
                  before: before, after: after,
                  explanation: 'Published record changed; see retained before and after evidence.')
        end
      end
    end
  end
end

require 'muni/water/sensor_shifts'
require 'muni/water/gaps'
