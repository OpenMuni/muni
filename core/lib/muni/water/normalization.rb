module Muni
  module Water
    # A versioned interpretation of an immutable publisher record. Raw payloads,
    # publisher IDs and original units are never rewritten by this projection.
    module Normalization
      VERSION = 'water-normalization-v1'.freeze
      CRWA_IMPORTER_METHOD = 'Published CRWA dashboard; laboratory method not supplied'.freeze
      REJECTED_STATUSES = %w[retracted rejected needs_review].freeze
      BIOLOGICAL_ABUNDANCE = %w[ecoli estimated_cyanobacteria estimated_chlorophyll_a].freeze
      EXCLUDED_FLAGS = %w[invalid_numeric_value unparsed_source_value negative_biological_estimate
                          cross_source_unit_conflict].freeze
      SAMPLING_FIELDS = {
        project_ids: 'Project_Identifier', medium: 'Activity_Media', medium_subdivision: 'Activity_MediaSubdivision',
        relative_depth: 'Activity_ActivityRelativeDepth', depth: 'Activity_DepthHeightMeasure',
        depth_unit: 'Activity_DepthHeightMeasureUnit', depth_reference: 'Activity_BottomDepthAltitudeReferencePoint',
        collection_method_id: 'SampleCollectionMethod_Identifier', collection_method: 'SampleCollectionMethod_Name',
        field_note: 'Activity_Comment', laboratory: 'LabInfo_Name',
        analytical_method_id: 'ResultAnalyticalMethod_Identifier',
        analytical_method: 'ResultAnalyticalMethod_Name', qapp_approved: 'Project_QAPPApproved',
        qapp_approval_agency: 'Project_QAPPApprovalAgency', result_comment: 'DataQuality_ResultComment',
        result_depth: 'ResultDepthHeight_Measure', result_depth_unit: 'ResultDepthHeight_MeasureUnit',
        result_depth_reference: 'ResultDepthHeight_AltitudeReferencePoint'
      }.freeze

      module_function

      def call(record)
        row = record.transform_keys(&:to_sym)
        payload = decoded(row[:payload]).transform_keys(&:to_sym)
        raw = decoded(row[:raw]).transform_keys(&:to_s)
        row = row.merge(payload: payload, normalization_version: VERSION)
        payload[:normalization_version] = VERSION
        normalize_date(row, raw, payload)
        normalize_sample(row, raw, payload) if row[:kind] == 'laboratory'
        normalize_result(row, payload)
        provenance(row, raw, payload)
        row
      end

      def decoded(value)
        value.is_a?(String) ? JSON.parse(value) : (value || {})
      rescue JSON::ParserError
        {}
      end

      def normalize_date(row, raw, payload)
        instant = Water.time(row[:observed_at])
        date, precision = date_components(row, raw, payload, instant)
        row[:observed_date] = date && Date.iso8601(date.to_s).iso8601
        row[:time_precision] = precision
        payload[:observed_date] = row[:observed_date]
        payload[:time_precision] = precision
        if precision == 'date' && raw['Date_Collected'].nil?
          payload.delete(:source_observed_at)
        else
          payload[:source_observed_at] ||= instant&.iso8601
        end
        row[:observed_at] = nil if precision == 'date'
      rescue ArgumentError, TypeError, RangeError
        row[:observed_date] = nil
        row[:observed_at] = nil
        row[:status] = 'needs_review'
        payload[:review_reason] = 'Invalid published observation date; original value retained.'
      end

      def date_components(row, raw, payload, instant)
        if row[:source_slug].to_s.end_with?('/crwa_laboratory') && raw['Date_Collected']
          # Mixed UTC-midnight and Eastern-midnight encodings retain the nominal
          # UTC calendar date, never an invented observation instant.
          return [Time.at(Float(raw['Date_Collected']) / 1000.0).utc.to_date.iso8601, 'date']
        end

        date = [row[:observed_date], payload[:observed_date], payload[:sample_date], payload[:event_date],
                raw['Activity_StartDate']].find { |value| present?(value) }
        date ||= Clock.day(instant).iso8601 if instant
        precision = row[:time_precision] || payload[:time_precision] || ('time' if instant)
        [date, precision]
      end

      def normalize_sample(row, raw, payload)
        type = payload[:sample_type] || raw['Activity_TypeCode']
        payload[:sample_role] = sample_role(type, payload[:routine_sample])
        payload[:sample_type] = type
        payload[:activity_id] ||= raw['Activity_ActivityIdentifier']
        payload[:sample_id] = Water.hash([row[:source_slug], payload[:activity_id]]) if present?(payload[:activity_id])
        payload[:sampling] = SAMPLING_FIELDS.transform_values { |field| raw[field] }.compact
                                            .merge(decoded(payload[:sampling]).transform_keys(&:to_sym))
        publication_identity(row, raw, payload)
        payload[:method_status] = present?(row[:method]) || present?(row[:segment]) ? 'supplied' : 'not_supplied'
      end

      def sample_role(type, routine)
        return 'routine' if type == 'Sample-Routine'
        return 'qc' if type.to_s.start_with?('Quality Control')
        return 'routine' if routine == true
        return 'nonroutine' if routine == false

        'unknown'
      end

      def publication_identity(row, raw, payload)
        if row[:source_slug].to_s.end_with?('/crwa_laboratory')
          payload[:publication_group_id] = Water.hash([row[:source_slug], raw.except('FID', 'GlobalID')])
          payload[:identity_status] = 'publication_only'
          # Earlier imports used our own source label as a method. Keeping it
          # only on retained records makes identical fresh publications differ.
          payload.delete(:method_description) if payload[:method_description] == CRWA_IMPORTER_METHOD
          row[:method] = nil if row[:method] == CRWA_IMPORTER_METHOD
        else
          payload[:identity_status] = present?(payload[:activity_id]) ? 'source_activity' : 'publication_only'
        end
      end

      def normalize_result(row, payload)
        payload[:original_value] = row[:value] unless payload.key?(:original_value)
        payload[:original_unit] ||= row[:unit]
        payload[:normalized_unit] = normalized_unit(row[:unit])
        relation = relation(payload)
        payload[:result_relation] = relation
        normalize_bound(row, payload, relation)
        payload[:quality_flags] = quality_flags(row, payload, relation)
        row[:value] = relation == 'exact' ? finite_number(row[:value]) : nil
        reasons = exclusion_reasons(row, payload, relation)
        payload[:calculation_exclusion_reasons] = reasons.uniq
        payload[:calculation_eligible] = reasons.empty?
      end

      def normalize_bound(row, payload, relation)
        payload[:comparator] = { 'less_than' => '<', 'less_than_or_equal' => '<=',
                                 'greater_than' => '>', 'greater_than_or_equal' => '>=' }[relation]
        limit = finite_number(payload[:detection_limit] || payload[:volume_limit])
        unless relation == 'exact'
          limit ||= finite_number(payload[:original_value].to_s.sub(/\A\s*(?:[<>]=?|[≤≥])\s*/,
                                                                    ''))
        end
        payload[:limit_value] = limit
        payload[:limit_unit] = payload[:detection_unit] || row[:unit] if limit
      end

      def quality_flags(row, payload, relation)
        flags = Array(payload[:quality_flags]).dup
        value = finite_number(row[:value])
        flags << 'invalid_numeric_value' if row[:value] && !value
        original = payload[:original_value]
        if value.nil? && present?(original) && relation == 'exact' && !finite_number(original)
          flags << 'unparsed_source_value'
        end
        flags << 'negative_biological_estimate' if value&.negative? && BIOLOGICAL_ABUNDANCE.include?(row[:parameter])
        flags << 'negative_fluorescence' if value&.negative? && row[:unit].to_s.casecmp('RFU').zero?
        flags.uniq
      end

      def exclusion_reasons(row, payload, relation)
        reasons = []
        reasons << 'publisher_status' if REJECTED_STATUSES.include?(row[:status].to_s.downcase)
        reasons << 'censored_result' unless relation == 'exact'
        reasons << 'missing_value' if row[:value].nil?
        reasons.concat(payload[:quality_flags] & EXCLUDED_FLAGS)
        reasons.concat(laboratory_exclusions(payload)) if row[:kind] == 'laboratory'
        reasons << 'notice_not_countable' if row[:kind] == 'discharge' && payload[:countable] == false
        reasons
      end

      def laboratory_exclusions(payload)
        role_reason = { 'qc' => 'quality_control_sample', 'nonroutine' => 'nonroutine_sample',
                        'unknown' => 'sample_role_unknown' }[payload[:sample_role]]
        [role_reason, ('analytical_method_unknown' if payload[:method_status] == 'not_supplied')].compact
      end

      def relation(payload)
        text = [payload[:qualifier], payload[:original_value], payload[:volume_qualifier]].compact.join(' ')
        condition = payload[:detection_condition].to_s.downcase
        return 'less_than_or_equal' if text.match?(/<=|≤/)
        return 'greater_than_or_equal' if text.match?(/>=|≥/)
        return 'less_than' if text.include?('<') || condition.match?(/not detected|below|less than/)
        return 'greater_than' if text.include?('>') || condition.match?(/above|greater than|exceed/)
        return 'detected_not_quantified' if condition.match?(/detected.*not.*quantif|present.*not.*quantif/)
        return 'qualified' if present?(payload[:detection_condition])

        'exact'
      end

      def normalized_unit(unit)
        case unit.to_s.downcase.delete(' ')
        when 'cfu/100ml' then 'CFU/100mL'
        when 'mpn/100ml' then 'MPN/100mL'
        else unit
        end
      end

      def provenance(row, raw, payload)
        payload[:source_provenance] = decoded(payload[:source_provenance]).transform_keys(&:to_sym).merge(
          record_id: payload[:source_record_id], source_url: row[:source_url],
          source_status: row[:status], source_observed_at: payload[:source_observed_at],
          source_date_value: raw['Date_Collected'] || raw['Activity_StartDate'] || raw['date'],
          source_time_value: raw['Activity_StartTime'], source_timezone: row[:original_timezone],
          source_changed_at: raw['LastChangeDate']
        ).compact
      end

      def finite_number(value)
        parsed = Float(value, exception: false)
        parsed if parsed&.finite?
      end

      def present?(value) = !value.nil? && !value.to_s.strip.empty?
    end
  end
end
