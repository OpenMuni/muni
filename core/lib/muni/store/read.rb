require 'time'

module Muni
  module Store
    module Read
      def distinct_values(klass, field, hall: nil, since: nil, since_field: nil, limit: 20, **where)
        raise "Record #{klass} has no schema" unless klass.schema_def

        ds = db[klass.table_name.to_sym]
        ds = ds.where(hall_scope(hall)) if hall
        ds = ds.where(where) unless where.empty?
        if since
          time_col = time_column(klass, preferred: since_field)
          ds = ds.where(Sequel.lit("#{time_col} >= ?", since)) if time_col
        end
        ds.distinct.select(field).limit(limit).all
          .map { |r| r[field] }
          .compact
          .reject { |value| value.to_s.strip.empty? }
          .sort
      end

      def latest_time(klass, hall: nil, time_field: nil, **where)
        schema = klass.schema_def or raise "Record #{klass} has no schema"
        time_col = time_column(schema, preferred: time_field)
        return nil unless time_col

        ds = db[klass.table_name.to_sym]
        ds = ds.where(hall_scope(hall)) if hall
        ds = ds.where(where) unless where.empty?
        value = ds.max(time_col)
        value.nil? ? nil : parse_db_time(value)
      end

      def time_column(klass_or_schema, preferred: nil)
        schema = klass_or_schema.respond_to?(:schema_def) ? klass_or_schema.schema_def : klass_or_schema
        return nil unless schema

        candidate = preferred&.to_sym
        return candidate if candidate && schema.columns.any? { |c| c.type == :time && c.name == candidate }

        pick_time_column(schema)
      end

      private

      def parse_db_time(value)
        if value.is_a?(Time)
          return Time.utc(value.year, value.month, value.day, value.hour, value.min, value.sec + value.subsec)
        end

        text = value.to_s
        zoned = text.match?(/(?:z|[+-]\d{2}:?\d{2})\z/i)
        Time.parse(zoned ? text : "#{text} UTC")
      end
    end

    extend Read
  end
end
