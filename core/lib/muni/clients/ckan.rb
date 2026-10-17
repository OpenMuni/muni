require 'digest'
require 'json'
require 'time'
require 'muni/helpers/http'

module Muni
  module Clients
    # Small CKAN Action API client used by Analyze Boston collectors. It keeps
    # resource IDs out of source code and pages DataStore rows without building
    # one city-sized response in memory.
    class Ckan
      PAGE_SIZE = 1_000

      def initialize(base_url:, page_size: PAGE_SIZE)
        @http = Muni::Helpers::Http.new(base_url: base_url, timeout: 45)
        @page_size = page_size.to_i.clamp(1, 5_000)
        @packages = {}
      end

      def package(id, refresh: false)
        @packages.delete(id.to_s) if refresh
        @packages[id.to_s] ||= action('package_show', id: id).fetch('result')
      end

      def resources(package_id, datastore_only: true, refresh: false)
        rows = Array(package(package_id, refresh: refresh)['resources'])
        datastore_only ? rows.select { |row| row['datastore_active'] } : rows
      end

      def resolve_resource(package_id, name: nil, name_pattern: nil, fields: nil, refresh: false)
        candidates = resources(package_id, refresh: refresh)
        candidates = candidates.select { |row| row['name'].to_s.casecmp?(name.to_s) } if name
        if name_pattern
          pattern = name_pattern.is_a?(Regexp) ? name_pattern : /#{Regexp.escape(name_pattern.to_s)}/i
          candidates = candidates.select { |row| row['name'].to_s.match?(pattern) }
        end
        if fields
          required = Array(fields).map(&:to_s)
          candidates = candidates.select do |row|
            available = resource_fields(row.fetch('id'))
            required.all? { |field| available.include?(field) }
          end
        end

        candidates.max_by { |row| resource_timestamp(row) } ||
          raise(ArgumentError, "no CKAN resource matched #{package_id}")
      end

      def resource_fields(resource_id)
        result = action('datastore_search', resource_id: resource_id, limit: 0).fetch('result')
        Array(result['fields']).map { |field| field['id'].to_s }
      end

      def each_row(resource:, limit: nil, offset: 0, filters: nil, sort: nil, fields: nil, &block)
        unless block_given?
          return enum_for(__method__, resource: resource, limit: limit, offset: offset,
                          filters: filters, sort: sort, fields: fields)
        end

        read = 0
        next_offset = offset.to_i
        loop do
          remaining = limit && (limit.to_i - read)
          break if remaining && remaining <= 0

          page_limit = [@page_size, remaining].compact.min
          params = { resource_id: resource, limit: page_limit, offset: next_offset }
          params[:filters] = JSON.generate(filters) if filters && !filters.empty?
          params[:sort] = sort if sort
          params[:fields] = Array(fields).join(',') if fields
          batch = Array(action('datastore_search', **params).dig('result', 'records'))
          batch.each(&block)
          read += batch.length
          break if batch.length < page_limit

          next_offset += batch.length
        end
        read
      end

      def query(**args)
        each_row(**args).to_a
      end

      def each_sql(resource:, where: nil, order: nil, limit: nil, offset: 0, &block)
        unless block_given?
          return enum_for(__method__, resource: resource, where: where, order: order,
                          limit: limit, offset: offset)
        end

        raise ArgumentError, 'invalid CKAN resource ID' unless resource.to_s.match?(/\A[0-9a-z_-]+\z/i)

        read = 0
        next_offset = offset.to_i
        loop do
          remaining = limit && (limit.to_i - read)
          break if remaining && remaining <= 0

          page_limit = [@page_size, remaining].compact.min
          sql = %(SELECT * FROM "#{resource}")
          sql += " WHERE #{where}" if where && !where.to_s.empty?
          sql += " ORDER BY #{order}" if order && !order.to_s.empty?
          sql += " LIMIT #{page_limit.to_i} OFFSET #{next_offset.to_i}"
          batch = Array(action('datastore_search_sql', sql: sql).dig('result', 'records'))
          batch.each(&block)
          read += batch.length
          break if batch.length < page_limit

          next_offset += batch.length
        end
        read
      end

      def resource_signature(resource)
        identity = %w[id hash last_modified created url].map { |key| resource[key].to_s }.join('|')
        Digest::SHA256.hexdigest(identity)
      end

      private

      def action(name, **params)
        response = @http.get("/api/3/action/#{name}", params)
        return response if response['success']

        raise Muni::Helpers::Http::Error.new(502, response['error'])
      end

      def resource_timestamp(resource)
        Time.parse(resource['last_modified'] || resource['created'] || '1970-01-01')
      rescue ArgumentError
        Time.at(0)
      end
    end
  end
end
