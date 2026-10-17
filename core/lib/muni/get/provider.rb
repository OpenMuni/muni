module Muni
  module Get
    # One upstream binding for a domain: which Source to pull and which Record type
    # is emitted. Optional +row_filter+ narrows rows after normalization.
    Provider = Struct.new(
      :key,
      :source_slug,
      :record_slug,
      :pull_options,
      :row_filter,
      keyword_init: true
    ) do
      def source_class
        Muni::Registry.source(source_slug) or
          raise ArgumentError, "unknown source: #{source_slug}"
      end

      def record_class
        Muni::Registry.record(record_slug) or
          raise ArgumentError, "unknown record: #{record_slug}"
      end
    end
  end
end
