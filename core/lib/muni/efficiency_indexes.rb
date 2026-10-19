# The index migration deliberately audits and changes several related tables atomically.
# rubocop:disable-next Metrics/AbcSize, Metrics/BlockLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
module Muni
  module EfficiencyIndexes
    SORT_SQL = "COALESCE(opened_at, updated_at, closed_at, collected_at, '1970-01-01 00:00:00.000000')".freeze

    MAP_COLUMNS = %i[hall opened_at external_id status lifecycle_source_state closed_at updated_at acknowledged_at
                     collected_at last_seen_at case_type department neighborhood].freeze

    POINT_COLUMNS = %i[hall external_id in_boundary x y lon lat].freeze

    class << self
      def equivalent?(db, table, columns)
        !matching_index(db, table, columns).nil?
      end

      def matching_index(db, table, columns)
        match = definitions(db, table).find do |index|
          index[:unique].zero? && index[:partial].zero? &&
            index[:keys].map { |key| [key[2], key[3], key[4]] } == columns.map { |column| [column.to_s, 0, 'BINARY'] }
        end
        match && match[:name]
      end

      def ensure_sort_column!(db)
        present = db.fetch('PRAGMA table_xinfo(service_requests)').any? do |column|
          column[:name] == 'efficiency_sort_at'
        end
        return if present

        db.run('ALTER TABLE service_requests ADD COLUMN efficiency_sort_at TEXT GENERATED ALWAYS AS ' \
               "(#{SORT_SQL}) VIRTUAL")
      end

      def prepare!
        db = Muni::Store.db
        Muni::Store.with_writer do
          db.transaction do
            db.create_table?(:efficiency_index_changes) do
              String :name, primary_key: true
              String :table_name, null: false
              String :recreate_sql, text: true, null: false
              DateTime :removed_at, null: false
            end
            db.tables.each do |table|
              groups = definitions(db, table).select { |index| index[:unique].zero? && index[:origin] == 'c' }
              groups.group_by { |index| [index[:keys], index[:partial], index[:predicate]] }.each_value do |duplicates|
                next if duplicates.length < 2

                ordered = duplicates.sort_by { |index| [index[:name].include?('_pk_migration_') ? 1 : 0, index[:name]] }
                ordered.drop(1).each do |index|
                  audit = { name: index[:name], table_name: table.to_s, recreate_sql: index[:sql],
                            removed_at: Time.now.utc }
                  db[:efficiency_index_changes].insert_conflict(target: :name,
                                                                update: audit.except(:name)).insert(audit)
                  db.run("DROP INDEX #{quote(index[:name])}")
                end
              end
            end
            unless equivalent?(db, :service_requests, %i[hall efficiency_sort_at external_id])
              db.run('CREATE INDEX service_requests_efficiency_order ' \
                     'ON service_requests (hall, efficiency_sort_at, external_id)')
            end
            unless equivalent?(db, :service_requests, MAP_COLUMNS)
              db.run('CREATE INDEX service_requests_lifecycle_map_filters ON service_requests ' \
                     "(#{MAP_COLUMNS.join(', ')})")
            end
            unless equivalent?(db, :service_request_map_points, POINT_COLUMNS)
              db.run('CREATE INDEX service_request_map_cover ON service_request_map_points ' \
                     "(#{POINT_COLUMNS.join(', ')})")
            end
            db.run("ANALYZE #{quote(matching_index(db, :service_requests, MAP_COLUMNS))}")
            db.run("ANALYZE #{quote(matching_index(db, :service_request_map_points, POINT_COLUMNS))}")
          end
        end
      end

      def definitions(db, table)
        db.fetch("PRAGMA index_list(#{quote(table)})").all.filter_map do |row|
          sql = db[:sqlite_master].where(type: 'index', name: row[:name]).get(:sql)
          next unless sql

          keys = db.fetch("PRAGMA index_xinfo(#{quote(row[:name])})").all.select { |key| key[:key] == 1 }
                   .map do |key|
            [
              key[:seqno], key[:cid], key[:name], key[:desc], key[:coll], key[:key]
            ]
          end
          # Expression indexes need their expression text compared, not just cid=-2.
          predicate = if keys.any? { |key| key[1] == -2 }
                        sql.sub(/\ACREATE\s+(?:UNIQUE\s+)?INDEX\s+.*?\s+ON\s+[^()]+/im, '')
                      else
                        sql[/\bWHERE\s+.+\z/im]
                      end
          row.merge(sql: sql, keys: keys, predicate: predicate)
        end
      end

      private

      def quote(name)
        "\"#{name.to_s.gsub('"', '""')}\""
      end
    end
  end
end
