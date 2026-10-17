module Muni
  # Resolves a human place string to a configured Hall without city-id tables.
  #
  #   Zone.parse('cambridge')        # => hall cambridge
  #   Zone.parse('cambridge,ma')     # => hall cambridge
  #
  # State defaults to MA for the MVP city. Unknown slugs raise Zone::Unknown.
  class Zone
    class Unknown < StandardError
      def initialize(input)
        super("unknown zone: #{input.inspect} (try: #{Muni::Hall.all.map(&:slug).join(', ')})")
      end
    end

    DEFAULT_STATE = 'MA'.freeze

    attr_reader :hall, :state, :input

    def initialize(hall:, state:, input:)
      @hall = hall
      @state = state.to_s.upcase
      @input = input
    end

    def slug = hall.slug

    def label
      state == DEFAULT_STATE ? hall.name.to_s : "#{hall.name.split(',').first}, #{state}"
    end

    def to_h
      { slug: slug, state: state, name: hall.name, input: input }
    end

    class << self
      def parse(input)
        return nil if input.nil? || input.to_s.strip.empty?

        raw = input.to_s.strip
        normalized = raw.downcase.gsub(/[, ]+/, ',')
        parts = normalized.split(',').map(&:strip).reject(&:empty?)
        slug = parts[0]
        state = (parts[1] || DEFAULT_STATE).upcase

        hall = find_hall(slug, state) or raise Unknown, raw
        new(hall: hall, state: state, input: raw)
      end

      def parse!(input)
        parse(input) or raise Unknown, input
      end

      private

      def find_hall(slug, _state)
        Muni::Hall.all.find { |h| h.slug == slug } ||
          Muni::Hall.all.find { |h| h.name.downcase.start_with?(slug) }
      end
    end
  end
end
