require 'muni/analytics/support'
require 'muni/analytics/service_request_resolution'
require 'muni/analytics/permit_processing'
require 'muni/analytics/crash_risk'
require 'muni/analytics/service_request_anomalies'
require 'muni/analytics/safety_hotspots'
require 'muni/analytics/safety_anomalies'
require 'muni/analytics/police_log_anomalies'
require 'muni/analytics/crash_exposure_risk'
require 'muni/analytics/civic_digest'

module Muni
  module Analytics
    SERVICE_REQUEST_MODEL = 'service_request_resolution_model'.freeze
    PERMIT_MODEL = 'permit_processing_model'.freeze
    CRASH_RISK_LOCATIONS = 'crash_risk_locations'.freeze
    SERVICE_REQUEST_ANOMALIES = 'service_request_volume_anomalies'.freeze
    SAFETY_HOTSPOTS = 'safety_hotspots'.freeze
    SAFETY_ANOMALIES = 'safety_anomalies'.freeze
    POLICE_LOG_ANOMALIES = 'police_log_volume_anomalies'.freeze
    CRASH_EXPOSURE_RISK = 'crash_exposure_risk'.freeze
    CIVIC_DIGEST = 'civic_digest'.freeze
    DEFAULT_KEY = 'default'.freeze
    ROW_COUNT_COLLECTIONS = {
      CRASH_RISK_LOCATIONS      => %w[locations crash_count],
      SERVICE_REQUEST_ANOMALIES => %w[anomalies current_count],
      SAFETY_HOTSPOTS           => %w[locations count],
      SAFETY_ANOMALIES          => %w[anomalies current_count],
      POLICE_LOG_ANOMALIES      => %w[anomalies current_count],
      CRASH_EXPOSURE_RISK       => %w[locations crash_count]
    }.freeze

    module_function

    def compute!(hall:, now: Time.now.utc)
      Muni::Store.ensure_tables!
      generated_at = Support.time_value(now) || Time.now.utc
      enforce_retention!(hall: hall, now: generated_at)
      payloads = {
        SERVICE_REQUEST_MODEL     => ServiceRequestResolution.train(hall: hall, now: generated_at),
        PERMIT_MODEL              => PermitProcessing.train(hall: hall, now: generated_at),
        CRASH_RISK_LOCATIONS      => CrashRisk.compute(hall: hall, now: generated_at),
        SERVICE_REQUEST_ANOMALIES => ServiceRequestAnomalies.compute(hall: hall, now: generated_at),
        SAFETY_HOTSPOTS           => SafetyHotspots.compute(hall: hall, now: generated_at),
        SAFETY_ANOMALIES          => SafetyAnomalies.compute(hall: hall, now: generated_at),
        POLICE_LOG_ANOMALIES      => PoliceLogAnomalies.compute(hall: hall, now: generated_at),
        CRASH_EXPOSURE_RISK       => CrashExposureRisk.compute(hall: hall, now: generated_at)
      }

      payloads.each do |kind, payload|
        Muni::Store.upsert_analytics_result(
          hall:             hall,
          kind:             kind,
          key:              DEFAULT_KEY,
          payload:          payload,
          generated_at:     generated_at,
          source_row_count: source_row_count(kind, payload),
          source_max_at:    payload['source_max_at']
        )
      end

      snapshot(hall: hall)
    end

    def enforce_retention!(hall:, now: Time.now.utc)
      hall_record = Muni::Hall.find(hall)
      return 0 unless hall_record

      hall_record.source_slugs.sum do |slug|
        source = Muni::Registry.source(slug)
        source ? Muni::Store.enforce_source_retention(source, now: now) : 0
      end
    end

    def snapshot(hall:)
      Muni::Store.ensure_tables!
      service = cached_payload(hall, SERVICE_REQUEST_MODEL)
      permit = cached_payload(hall, PERMIT_MODEL)
      crash = cached_payload(hall, CRASH_RISK_LOCATIONS)
      anomalies = cached_payload(hall, SERVICE_REQUEST_ANOMALIES)
      safety_hotspots = cached_payload(hall, SAFETY_HOTSPOTS)
      safety_anomalies = cached_payload(hall, SAFETY_ANOMALIES)
      police_log_anomalies = cached_payload(hall, POLICE_LOG_ANOMALIES)
      crash_exposure_risk = cached_payload(hall, CRASH_EXPOSURE_RISK)
      civic_digest = cached_payload(hall, CIVIC_DIGEST)
      payloads = [service, permit, crash, anomalies, safety_hotspots, safety_anomalies, police_log_anomalies,
                  crash_exposure_risk, civic_digest].compact

      {
        status:                    payloads.any? { |payload| payload['status'] == 'ready' } ? 'ready' : 'warming',
        generated_at:              latest(payloads, 'generated_at'),
        service_requests:          service_summary(service),
        permits:                   permit_summary(permit),
        crash_risks:               crash || warming_list('locations'),
        service_request_anomalies: anomalies || warming_list('anomalies'),
        safety_hotspots:           safety_hotspots || warming_list('locations'),
        safety_anomalies:          safety_anomalies || warming_list('anomalies'),
        police_log_anomalies:      police_log_anomalies || warming_list('anomalies'),
        crash_exposure_risk:       crash_exposure_risk || warming_list('locations'),
        civic_digest:              civic_digest
      }
    end

    def compute_digest!(hall:, now: Time.now.utc)
      Muni::Store.ensure_tables!
      generated_at = Support.time_value(now) || Time.now.utc
      payload = CivicDigest.compute(hall: hall, now: generated_at)
      return 0 unless payload

      Muni::Store.upsert_analytics_result(
        hall:             hall,
        kind:             CIVIC_DIGEST,
        key:              DEFAULT_KEY,
        payload:          payload,
        generated_at:     generated_at,
        source_row_count: Array(payload['cards']).length,
        source_max_at:    payload['source_max_at'] || generated_at
      )
      1
    end

    def digest(hall:)
      payload = cached_payload(hall, CIVIC_DIGEST)
      normalized = normalize_digest_payload(payload) if payload
      return normalized if source_backed_digest_payload?(normalized)

      CivicDigest.compute(hall: hall) || CivicDigest.warming_payload(hall: hall)
    end

    def digest_context(hall:, now: Time.now.utc)
      CivicDigest.source_payload(hall: hall, now: now)
    end

    def predict_service_request(hall:, attrs:)
      model = Muni::Store.analytics_result(hall: hall, kind: SERVICE_REQUEST_MODEL, key: DEFAULT_KEY)
      ServiceRequestResolution.predict(model, attrs).merge(type: 'service_requests')
    end

    def predict_permit(hall:, attrs:)
      model = Muni::Store.analytics_result(hall: hall, kind: PERMIT_MODEL, key: DEFAULT_KEY)
      PermitProcessing.predict(model, attrs).merge(type: 'permits')
    end

    def crash_risks(hall:, limit: 25)
      payload = cached_payload(hall, CRASH_RISK_LOCATIONS) || warming_list('locations')
      payload.merge('locations' => Array(payload['locations']).first(limit.to_i.clamp(1, 100)))
    end

    def service_request_anomalies(hall:, limit: 25)
      payload = cached_payload(hall, SERVICE_REQUEST_ANOMALIES) || warming_list('anomalies')
      payload.merge('anomalies' => Array(payload['anomalies']).first(limit.to_i.clamp(1, 100)))
    end

    def cached_payload(hall, kind)
      row = Muni::Store.analytics_result(hall: hall, kind: kind, key: DEFAULT_KEY)
      return nil unless row

      payload = row[:payload] || {}
      payload['generated_at'] ||= Support.iso_time(row[:generated_at])
      payload['source_max_at'] ||= Support.iso_time(row[:source_max_at])
      payload
    end

    def normalize_digest_payload(payload)
      payload = payload.dup
      payload['schema_version'] ||= 2
      payload['title'] = CivicDigest::TITLE
      payload.delete('body')
      Array(payload['cards']).each do |card|
        card['section_key'] = 'city_today' if card.is_a?(Hash) && card['section_key'] == 'today_in_cambridge'
      end
      Array(payload['sections']).each do |section|
        next unless section.is_a?(Hash) && section['key'] == 'today_in_cambridge'

        section['key'] = 'city_today'
        section['label'] = 'Today'
      end
      payload
    end

    def source_backed_digest_payload?(payload)
      return false unless payload
      return true if payload['status'].to_s == 'warming' && Array(payload['cards']).empty?

      Array(payload['cards']).any? do |card|
        next false unless card.is_a?(Hash)

        source_type = card['source_type'].to_s
        source_type != '' && source_type != 'trend_data_signal' && Array(card['sources']).any?
      end
    end

    def source_row_count(kind, payload)
      return payload['sample_size'] if [SERVICE_REQUEST_MODEL, PERMIT_MODEL].include?(kind)

      collection, field = ROW_COUNT_COLLECTIONS[kind]
      return nil unless collection

      Array(payload[collection]).sum { |row| row[field].to_i }
    end

    def service_summary(payload)
      return warming_model unless payload

      citywide = payload['citywide'] || {}
      {
        status:            payload['status'],
        generated_at:      payload['generated_at'],
        source_max_at:     payload['source_max_at'],
        sample_size:       payload['sample_size'].to_i,
        median_days:       citywide['median_days'],
        low_days:          citywide['low_days'],
        high_days:         citywide['high_days'],
        model_description: 'Empirical 311 close-time buckets'
      }
    end

    def permit_summary(payload)
      return warming_model unless payload

      citywide = payload['citywide'] || {}
      {
        status:            payload['status'],
        generated_at:      payload['generated_at'],
        source_max_at:     payload['source_max_at'],
        sample_size:       payload['sample_size'].to_i,
        median_days:       citywide['median_days'],
        low_days:          citywide['low_days'],
        high_days:         citywide['high_days'],
        model_description: 'Empirical permit issue-time buckets'
      }
    end

    def warming_model
      {
        status:            'warming',
        sample_size:       0,
        median_days:       nil,
        low_days:          nil,
        high_days:         nil,
        model_description: nil
      }
    end

    def warming_list(name)
      {
        'status'       => 'warming',
        'generated_at' => nil,
        name           => []
      }
    end

    def latest(payloads, field)
      payloads.filter_map { |payload| Support.time_value(payload[field]) }.max&.iso8601
    end

    class NullSource
      def pull(**)
        []
      end
    end
  end
end
