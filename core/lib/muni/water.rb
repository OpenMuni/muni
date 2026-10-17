require 'csv'
require 'date'
require 'digest'
require 'json'
require 'securerandom'
require 'zlib'

module Muni
  module Water
    HALLS = %w[cambridge boston].freeze
    PREFIX = 'water/charles/'.freeze
    VERSION = 'water-v1'.freeze
    class Error < StandardError; end

    def self.enabled?
      ENV.fetch('MUNI_WATER_ENABLED', '0') == '1'
    end

    def self.presentation_enabled?
      ENV.fetch('MUNI_WATER_PRESENTATION_ENABLED', '1') == '1'
    end

    def self.processing_enabled?
      ENV.fetch('MUNI_WATER_PROCESSING_ENABLED', '1') == '1'
    end

    def self.canonical(value)
      case value
      when Hash then value.transform_keys(&:to_s).sort.to_h.transform_values { |v| canonical(v) }
      when Array then value.map { |v| canonical(v) }
      when Time then value.utc.iso8601
      else value
      end
    end

    def self.json(value)
      JSON.generate(canonical(value))
    end

    def self.hash(value)
      Digest::SHA256.hexdigest(json(value))
    end

    def self.time(value)
      return value.utc if value.is_a?(Time)
      return nil if value.nil? || value.to_s.empty?

      text = value.to_s
      text = "#{text} UTC" if text.match?(/\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?\z/)
      Time.parse(text).utc
    rescue ArgumentError
      nil
    end
  end
end

require 'muni/water/evidence'
require 'muni/water/catalog'
require 'muni/water/storage'
require 'muni/water/clock'
require 'muni/water/normalization'
require 'muni/water/eligibility'
require 'muni/water/client'
require 'muni/water/adapters/base'
require 'muni/water/adapters/crwa'
require 'muni/water/adapters/buoy'
require 'muni/water/adapters/laboratory'
require 'muni/water/adapters/usgs'
require 'muni/water/adapters/discharges'
require 'muni/water/evidence_writer'
require 'muni/water/daily_summaries'
require 'muni/water/calculations'
require 'muni/water/source_editions'
require 'muni/water/response_archive'
require 'muni/water/prepared_publication'
require 'muni/water/ingestor'
require 'muni/water/reconciler'
require 'muni/water/signals'
require 'muni/water/coverage'
require 'muni/water/metric_presentation'
require 'muni/water/record_projection'
require 'muni/water/query'
require 'muni/water/evidence_detail'
require 'muni/water/aggregated_series'
require 'muni/water/record_page'
require 'muni/water/daily_series'
require 'muni/water/metric_snapshots'
require 'muni/water/trends'
require 'muni/water/beat'
