module Muni
  # Thread-safe-ish (single-process) registry indexing everything declared
  # via the Source/Beat/Record/Hall DSLs.
  module Registry
    @sources = {}
    @records = {}
    @beats   = {}
    @halls   = {}

    class << self
      def register_source(klass)
        @sources[klass.slug] = klass
        klass
      end

      def register_record(klass)
        @records[klass.slug] = klass
        klass
      end

      def register_beat(klass)
        @beats[klass.slug] = klass
        klass
      end

      def register_hall(hall)
        @halls[hall.slug] = hall
        hall
      end

      def source(slug) = @sources.[](slug.to_s)
      def record(slug) = @records.[](slug.to_s)
      def beat(slug) = @beats.[](slug.to_s)
      def hall(slug) = @halls.[](slug.to_s)

      def sources = @sources.dup
      def records = @records.dup
      def beats = @beats.dup
      def halls = @halls.dup

      def deregister_source(slug) = @sources.delete(slug.to_s)
      def deregister_record(slug) = @records.delete(slug.to_s)
      def deregister_beat(slug)   = @beats.delete(slug.to_s)
      def deregister_hall(slug)   = @halls.delete(slug.to_s)

      def reset!
        @sources.clear
        @records.clear
        @beats.clear
        @halls.clear
      end
    end
  end
end
