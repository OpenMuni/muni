require 'muni/service_request_reconciliation'

module Muni
  module Beats
    class ServiceRequestLifecycle < Muni::Beat
      private

      def pull_and_persist(_started)
        return { rows_in: 0, rows_upserted: 0 } unless ENV['MUNI_311_RECONCILE'] == '1'

        result = Muni::ServiceRequestReconciliation.new(self.class.source_class.new, apply: true).run
        { rows_in:       result[:batches].sum { |batch| batch[:found] },
          rows_upserted: result[:batches].sum { |batch| batch[:persisted] } }
      end
    end

    class BostonServiceRequestLifecycle < ServiceRequestLifecycle
      beat 'boston/service_request_lifecycle', source: -> { Boston::ServiceRequests }, every: '15m'
    end

    class CambridgeServiceRequestLifecycle < ServiceRequestLifecycle
      beat 'cambridge/service_request_lifecycle', source: -> { Cambridge::ServiceRequests }, every: '15m'
    end
  end
end
