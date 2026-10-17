module Muni
  module Water
    # Capture a revision boundary with the input read transaction, then check
    # only newer revisions under the writer before publishing derived results.
    module CalculationFence
      module_function

      def verify!(cutoff, sources)
        changed = Storage.db[:water_revisions].where { id > cutoff }
        changed = changed.where(Sequel.function(:json_extract, :record, '$.source_slug') => sources)
        return unless changed.any?

        raise Error, 'Calculation inputs changed before publication; retrying current evidence'
      end
    end
  end
end
