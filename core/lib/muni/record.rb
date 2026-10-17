require 'json'

module Muni
  # Base class for normalized rows. Subclasses declare a schema:
  #
  #   class Muni::Records::ServiceRequest < Muni::Record
  #     schema do
  #       string  :external_id, primary: true
  #       string  :hall
  #       point   :location
  #       time    :opened_at
  #     end
  #   end
  #
  # Records are PORO-ish. They accept arbitrary kwargs at init time and only
  # the declared columns are persisted by `Muni::Store`. Anything extra (e.g.
  # `source:`) is kept as metadata on the instance.
  class Record
    TYPES = %i[string text integer float boolean time point json].freeze

    class Schema
      Column = Struct.new(:name, :type, :primary, :indexed, :default, keyword_init: true)

      attr_reader :columns

      def initialize
        @columns = []
      end

      TYPES.each do |t|
        define_method(t) do |name, primary: false, indexed: false, default: nil|
          @columns << Column.new(name: name, type: t, primary: primary, indexed: indexed, default: default)
        end
      end

      def primary_key
        col = @columns.find(&:primary)
        col&.name
      end

      def column_names
        @columns.map(&:name)
      end
    end

    class << self
      attr_reader :schema_def

      def schema(&block)
        @schema_def = Schema.new.tap { |s| s.instance_eval(&block) }
        Muni::Registry.register_record(self) if name
      end

      # 'service_requests' from Muni::Records::ServiceRequest
      def slug
        base = name.to_s.split('::').last
        base = "anonymous_#{object_id}" if base.nil? || base.empty?
        base.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
            .gsub(/([a-z\d])([A-Z])/, '\1_\2')
            .downcase
            .then { |s| s.end_with?('s') ? s : "#{s}s" }
      end

      def table_name
        slug
      end
    end

    attr_reader :attributes, :metadata

    def initialize(**attrs)
      declared = self.class.schema_def&.column_names || []
      @attributes = {}
      @metadata = {}
      attrs.each do |k, v|
        if declared.include?(k)
          @attributes[k] = v
        else
          @metadata[k] = v
        end
      end
    end

    def [](key)
      @attributes[key]
    end

    def []=(key, value)
      @attributes[key] = value
    end

    def respond_to_missing?(name, include_private = false)
      column?(name.to_s.chomp('=').to_sym) || super
    end

    def method_missing(name, *args)
      base = name.to_s.chomp('=').to_sym
      return super unless column?(base)

      if name.to_s.end_with?('=')
        @attributes[base] = args.first
      else
        @attributes[base]
      end
    end

    def to_h
      @attributes.dup
    end

    def to_json(*)
      JSON.generate(to_h.transform_values { |v| v.is_a?(Time) ? v.iso8601 : v }, *)
    end

    def primary_key_value
      pk = self.class.schema_def&.primary_key
      pk && @attributes[pk]
    end

    private

    def column?(name)
      (self.class.schema_def&.column_names || []).include?(name)
    end
  end
end

# Namespace for shipped record types. Sources can also declare their own.
module Muni
  module Records
  end
end
