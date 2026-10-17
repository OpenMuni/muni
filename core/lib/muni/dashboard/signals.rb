module Muni
  module Dashboard
    module Signals
      def civic_signals(analytics, _widgets)
        police_log = police_log_signal(analytics)
        [
          anomaly_signal(analytics),
          police_log,
          safety_anomaly_signal(analytics, suppress_steady: police_log && field(police_log, :status) == 'watch'),
          safety_hotspot_signal(analytics),
          crash_risk_signal(analytics)
        ].compact
      end

      private

      def anomaly_signal(analytics)
        model = field(analytics, :service_request_anomalies) || {}
        anomalies = Array(field(model, :anomalies))
        window_days = anomaly_window_days(model)
        base = signal_base(
          '311_volume_anomalies', '311 Volume',
          category:     'service_requests',
          time_range:   '30d',
          source_at:    field(model, :source_max_at),
          generated_at: field(model, :generated_at),
          window_days:  window_days
        )

        return nil if warming_model?(model)
        return anomaly_steady_signal(base, window_days) if anomalies.empty?

        anomaly_watch_signal(base, anomalies, window_days)
      end

      def anomaly_steady_signal(base, window_days)
        base.merge(
          status:    'steady',
          tone:      'green',
          direction: 'steady',
          metric:    'OK',
          headline:  '311 volume steady',
          detail:    'No category is running above its normal range.',
          context:   "#{window_days}d window"
        )
      end

      def anomaly_watch_signal(base, anomalies, window_days)
        top = anomalies.first
        current_count = field(top, :current_count).to_i
        baseline_count = number_label(field(top, :baseline_count))
        case_type = field(top, :case_type) || '311'
        severity = field(top, :severity)
        base.merge(
          status:       'watch',
          tone:         severity == 'high' ? 'rose' : 'amber',
          direction:    'up',
          metric:       number_label(current_count),
          metric_label: 'new',
          headline:     case_type,
          detail:       'Requests above normal.',
          context:      "#{window_days}d vs #{baseline_count} typical",
          basis:        field(top, :basis),
          sample_size:  anomalies.sum { |row| field(row, :current_count).to_i },
          sample_label: 'current'
        )
      end

      def crash_risk_signal(analytics)
        model = field(analytics, :crash_risks) || {}
        locations = Array(field(model, :locations))
        base = signal_base(
          'crash_risk_hotspots', 'Crash Risk',
          category:     'crashes',
          time_range:   '90d',
          source_at:    field(model, :source_max_at),
          generated_at: field(model, :generated_at)
        )

        return nil if warming_model?(model) || locations.empty?

        top = locations.first
        crash_count = field(top, :crash_count).to_i
        base.merge(
          status:       'watch',
          tone:         'rose',
          direction:    'focus',
          metric:       number_label(field(top, :score)),
          metric_label: 'risk',
          headline:     display_label(field(top, :label), 'Mapped crash-risk cluster'),
          detail:       'Highest crash-risk location.',
          context:      count_phrase(crash_count, 'crash', 'crashes'),
          basis:        'weighted by recency and vulnerable-road-user involvement',
          sample_size:  locations.sum { |row| field(row, :crash_count).to_i },
          sample_label: 'crashes'
        )
      end

      def police_log_signal(analytics)
        model = field(analytics, :police_log_anomalies) || {}
        return nil if warming_model?(model)

        incident = Array(field(model, :incident_anomalies))
        publication = Array(field(model, :publication_anomalies))
        return police_log_publication_signal(model, publication) unless publication.empty?
        return police_log_incident_signal(model, incident) unless incident.empty?

        nil
      end

      def police_log_incident_signal(model, anomalies)
        top = anomalies.first
        base = police_log_signal_base(model, field(model, :incident_source_max_at))
        base.merge(
          status:       'watch',
          tone:         field(top, :severity) == 'high' ? 'rose' : 'amber',
          direction:    'up',
          metric:       number_label(field(top, :current_count)),
          metric_label: 'incidents',
          headline:     display_label(field(top, :label), 'Police-log incident activity'),
          detail:       'Police-log incident activity above normal by occurrence date.',
          context:      "#{field(model, :window_days).to_i}d occurred vs " \
                        "#{number_label(field(top, :baseline_count))} typical",
          basis:        field(top, :basis),
          sample_size:  anomalies.sum { |row| field(row, :current_count).to_i },
          sample_label: 'current'
        )
      end

      def police_log_publication_signal(model, anomalies)
        top = anomalies.first
        base = police_log_signal_base(model, field(model, :publication_source_max_at))
        base.merge(
          status:       'watch',
          tone:         'amber',
          direction:    'up',
          metric:       number_label(field(top, :current_count)),
          metric_label: 'published',
          headline:     'Police log publication volume',
          detail:       'Newly published police-log rows are above normal; this can reflect source catch-up.',
          context:      "#{field(model, :window_days).to_i}d reported vs " \
                        "#{number_label(field(top, :baseline_count))} typical",
          basis:        field(top, :basis),
          sample_size:  anomalies.sum { |row| field(row, :current_count).to_i },
          sample_label: 'published'
        )
      end

      def police_log_signal_base(model, source_at)
        signal_base(
          'police_log_volume_anomalies', 'Police Log',
          category:     'police',
          time_range:   'latest',
          source_at:    source_at || field(model, :source_max_at),
          generated_at: field(model, :generated_at),
          window_days:  field(model, :window_days).to_i
        )
      end

      def safety_anomaly_signal(analytics, suppress_steady: false)
        model = field(analytics, :safety_anomalies) || {}
        anomalies = Array(field(model, :anomalies))
        base = signal_base(
          'safety_anomalies', 'Safety',
          category:     'safety',
          time_range:   'latest',
          source_at:    field(model, :source_max_at),
          generated_at: field(model, :generated_at),
          window_days:  field(model, :window_days).to_i
        )

        return nil if warming_model?(model)
        return nil if suppress_steady && anomalies.empty?
        return safety_anomaly_steady_signal(base) if anomalies.empty?

        top = anomalies.first
        current_count = field(top, :current_count).to_i
        baseline_count = number_label(field(top, :baseline_count))
        base.merge(
          status:       'watch',
          tone:         field(top, :severity) == 'high' ? 'rose' : 'amber',
          direction:    'up',
          metric:       number_label(current_count),
          metric_label: 'recent',
          headline:     field(top, :label),
          detail:       'Safety activity above normal.',
          context:      "#{field(model, :window_days).to_i}d vs #{baseline_count} typical",
          basis:        field(top, :basis),
          sample_size:  anomalies.sum { |row| field(row, :current_count).to_i },
          sample_label: 'current'
        )
      end

      def safety_anomaly_steady_signal(base)
        base.merge(
          status:    'steady',
          tone:      'green',
          direction: 'steady',
          metric:    'OK',
          headline:  'Safety activity steady',
          detail:    'No current spike detected.',
          context:   'recent window'
        )
      end

      def safety_hotspot_signal(analytics)
        model = field(analytics, :safety_hotspots) || {}
        locations = Array(field(model, :locations))
        base = signal_base(
          'safety_hotspots', 'Safety Hotspots',
          category:     'safety',
          time_range:   'latest',
          source_at:    field(model, :source_max_at),
          generated_at: field(model, :generated_at)
        )

        return nil if locations.empty?

        top = locations.first
        count = field(top, :count).to_i
        base.merge(
          status:       'watch',
          tone:         'rose',
          direction:    'focus',
          metric:       number_label(field(top, :score)),
          metric_label: 'score',
          headline:     display_label(field(top, :label), 'Mapped safety cluster'),
          detail:       'Highest safety concentration.',
          context:      count_phrase(count, 'record'),
          basis:        'weighted by recency and source type',
          sample_size:  locations.sum { |row| field(row, :count).to_i },
          sample_label: 'records'
        )
      end

      def signal_base(id, title, **attrs)
        {
          id:    id,
          title: title
        }.merge(attrs)
      end

      def anomaly_window_days(model)
        days = field(model, :window_days).to_i
        return days if days.positive?

        Muni::Analytics::ServiceRequestAnomalies::CURRENT_WINDOW_DAYS
      end

      def warming_model?(model)
        field(model, :status).to_s == 'warming'
      end

      def field(hash, key)
        return nil unless hash.respond_to?(:key?)

        [key, key.to_s, key.to_sym].uniq.each do |candidate|
          return hash[candidate] if hash.key?(candidate)
        end

        nil
      end

      def number_label(value)
        number = float_value(value)
        return '0' unless number

        rounded = number.round(1)
        rounded == rounded.to_i ? rounded.to_i.to_s : rounded.to_s
      end

      def display_label(value, fallback)
        label = value.to_s.strip
        return fallback if label.empty?
        return fallback if label.match?(/\A-?\d{1,3}(?:\.\d+)?,\s*-?\d{1,3}(?:\.\d+)?\z/)

        label
      end

      def float_value(value)
        number = Float(value)
        number.finite? ? number : nil
      rescue ArgumentError, TypeError
        nil
      end

      def count_phrase(count, singular, plural = "#{singular}s")
        count == 1 ? "#{count} #{singular}" : "#{count} #{plural}"
      end
    end
  end
end
