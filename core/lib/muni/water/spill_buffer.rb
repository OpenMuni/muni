require 'tempfile'

module Muni
  module Water
    # Private, process-local staging. Large publications spill to disk before the
    # writer lock; only one batch is decoded at a time during atomic publication.
    class SpillBuffer
      include Enumerable

      attr_reader :length

      def initialize(limit: 1_048_576)
        @limit = limit
        @memory = []
        @bytes = 0
        @length = 0
      end

      def <<(value)
        encoded = Marshal.dump(value)
        spill! if !@file && @bytes + encoded.bytesize > @limit
        @file ? @file.write(encoded) : @memory << encoded
        @bytes += encoded.bytesize
        @length += 1
        self
      end

      # Marshal only decodes bytes written above, in a mode-0600 temporary file.
      # rubocop:disable Security/MarshalLoad
      def each
        return enum_for(:each) unless block_given?

        if @file
          @file.flush
          @file.rewind
          @length.times { yield Marshal.load(@file) } # Only this process writes this private file.
          @file.seek(0, IO::SEEK_END)
        else
          @memory.each { |encoded| yield Marshal.load(encoded) }
        end
      end

      # rubocop:enable Security/MarshalLoad

      def empty? = @length.zero?

      def close
        @file&.close!
        @file = nil
        @memory.clear
        @length = 0
      end

      private

      def spill!
        @file = Tempfile.new(['muni-publication-', '.stage'])
        @file.binmode
        @memory.each { |encoded| @file.write(encoded) }
        @memory.clear
      end
    end
  end
end
