require 'time'
require 'muni/local_time'
require 'muni/dashboard/source_status'
require 'muni/dashboard/signals'
require 'muni/dashboard/trends'

module Muni
  module Dashboard
    extend SourceStatus
    extend Signals
    extend Trends

    module_function

    DAY_SECONDS = 86_400

    def snapshot(hall:)
      now = Time.now.utc
      analytics = Muni::Analytics.snapshot(hall: hall)
      widgets = {
        service_requests:  service_request_widget(hall, now),
        safety:            safety_widget(hall, now),
        police:            police_widget(hall, now),
        permits:           permits_widget(hall, now),
        crashes:           crashes_widget(hall, now),
        traffic_volume:    traffic_volume_widget(hall, now),
        bicycle_counts:    bicycle_counts_widget(hall, now),
        pedestrian_counts: pedestrian_counts_widget(hall, now),
        trees:             trees_widget(hall)
      }

      {
        hall:         hall,
        generated_at: now.iso8601,
        sources:      source_statuses(hall),
        analytics:    analytics,
        signals:      civic_signals(analytics, widgets),
        widgets:      widgets
      }
    end

    def service_request_widget(hall, now)
      ds = dataset(Muni::Records::ServiceRequest, hall)
      return empty_widget unless ds

      times = service_request_times(hall, ds, now)
      open_ds = ds.exclude(status: %w[Closed Archived Resolved])
      closed_rows = ds.where(Sequel.lit('closed_at >= ?', times[:closed_window_start])).all

      {
        open_cases:           open_ds.count,
        opened_last_7d:       count_since(ds, :opened_at, times[:opened_since]),
        closed_last_7d:       count_since(ds, :closed_at, times[:closed_since]),
        opened_trend:         daily_trend(ds, :opened_at, days: 14, now: times[:opened_anchor]),
        closed_trend:         daily_trend(ds, :closed_at, days: 14, now: times[:closed_anchor]),
        resolution_trend:     rolling_duration_trend(
          ds, :closed_at, :opened_at, :closed_at, days: 30, now: times[:closed_anchor]
        ),
        median_close_seconds: median_duration(closed_rows, :opened_at, :closed_at),
        avg_close_seconds:    average_duration(closed_rows, :opened_at, :closed_at),
        stale_open_cases:     open_ds.where(Sequel.lit('opened_at < ?', times[:stale_cutoff])).count,
        aging_open:           aging_open_cases(open_ds.all, now),
        latest_opened_at:     iso_time(times[:latest_opened]),
        latest_closed_at:     iso_time(times[:latest_closed]),
        latest_updated_at:    iso_time(times[:latest_updated]),
        latest_source_at:     iso_time(times[:latest_source]),
        data_lag_seconds:     lag_seconds(now, times[:latest_source])
      }
    end

    def service_request_times(hall, dataset, now)
      latest_opened = time_value(dataset.max(:opened_at))
      latest_closed = time_value(dataset.max(:closed_at))
      latest_updated = time_value(dataset.max(:updated_at))
      latest_source = latest_source_time(hall, 'service_requests', latest_updated, latest_opened, latest_closed)
      opened_anchor = latest_opened || latest_source || now
      closed_anchor = latest_closed || latest_source || now

      {
        latest_opened:       latest_opened,
        latest_closed:       latest_closed,
        latest_updated:      latest_updated,
        latest_source:       latest_source,
        opened_anchor:       opened_anchor,
        closed_anchor:       closed_anchor,
        opened_since:        opened_anchor - (7 * DAY_SECONDS),
        closed_since:        closed_anchor - (7 * DAY_SECONDS),
        closed_window_start: closed_anchor - (30 * DAY_SECONDS),
        stale_cutoff:        now - (30 * DAY_SECONDS)
      }
    end

    def count_since(dataset, field, since)
      dataset.where(Sequel.lit("#{field} >= ?", since)).count
    end

    def police_widget(hall, now)
      ds = dataset(Muni::Records::PoliceLogEntry, hall)
      return empty_widget unless ds

      latest_reported = time_value(ds.max(:reported_at))
      latest_occurred = time_value(ds.max(:occurred_at))
      latest_source = latest_source_time(hall, 'police_log', latest_reported, latest_occurred)
      report_anchor = latest_reported || latest_source || now
      seven_days = report_anchor - (7 * DAY_SECONDS)
      recent = ds.where(Sequel.lit('reported_at >= ?', seven_days)).all
      lag_rows = ds.where(Sequel.lit('reported_at >= ?', report_anchor - (30 * DAY_SECONDS))).all
      {
        reports_last_7d:           recent.length,
        trend:                     daily_trend(ds, :reported_at, days: 14, now: report_anchor),
        report_lag_trend:          rolling_duration_trend(
          ds, :reported_at, :occurred_at, :reported_at, days: 14, now: report_anchor
        ),
        median_report_lag_seconds: median_duration(lag_rows, :occurred_at, :reported_at),
        by_type:                   counts_for(recent, :crime_category, limit: 8),
        latest_occurred_at:        iso_time(latest_occurred),
        latest_reported_at:        iso_time(latest_reported),
        latest_source_at:          iso_time(latest_source),
        data_lag_seconds:          lag_seconds(now, latest_source)
      }
    end

    def permits_widget(hall, now)
      ds = dataset(Muni::Records::BuildingPermit, hall)
      return empty_widget unless ds

      latest_issued = time_value(ds.max(:issued_at))
      latest_source = latest_source_time(hall, 'building_permits', latest_issued)
      issued_anchor = latest_issued || latest_source || now
      thirty_days = issued_anchor - (30 * DAY_SECONDS)
      recent = ds.where(Sequel.lit('issued_at >= ?', thirty_days)).all
      {
        permits_last_30d:                    recent.length,
        trend:                               daily_trend(ds, :issued_at, days: 30, now: issued_anchor),
        issue_lag_trend:                     rolling_duration_trend(ds, :issued_at, :applied_at, :issued_at,
                                                                    days: 30, now: issued_anchor),
        by_status:                           counts_for(recent, :status, limit: 8),
        by_type:                             counts_for(recent, :permit_type, limit: 8),
        median_application_to_issue_seconds: median_duration(recent, :applied_at, :issued_at),
        latest_issued_at:                    iso_time(latest_issued),
        latest_source_at:                    iso_time(latest_source),
        data_lag_seconds:                    lag_seconds(now, latest_source)
      }
    end

    def safety_widget(hall, now)
      crime = dataset(Muni::Records::CrimeReport, hall)
      dispatch = dataset(Muni::Records::DispatchCall, hall)
      recent_crashes = dataset(Muni::Records::CpdCrash, hall)
      return empty_widget unless crime || dispatch || recent_crashes

      latest = latest_time_for_sources([crime, :reported_at],
                                       [dispatch, :received_at],
                                       [recent_crashes, :occurred_at])
      anchor = latest || now
      since = anchor - (30 * DAY_SECONDS)
      crime_rows = since_rows(crime, :reported_at, since)
      dispatch_rows = since_rows(dispatch, :received_at, since)
      crash_rows = since_rows(recent_crashes, :occurred_at, since)
      {
        latest_source_at:   iso_time(latest),
        data_lag_seconds:   lag_seconds(now, latest),
        crime_reports_30d:  crime_rows.length,
        dispatch_calls_30d: dispatch_rows.length,
        recent_crashes_30d: crash_rows.length,
        dispatch_by_agency: counts_for(dispatch_rows, :agency, limit: 4),
        crime_by_type:      counts_for(crime_rows, :crime_category, limit: 5),
        crash_injuries_30d: crash_rows.count { |row| truthy?(row[:injury]) }
      }
    end

    def crashes_widget(hall, now)
      ds = dataset(Muni::Records::Crash, hall)
      return empty_widget.merge(source_mode: 'current-official') unless ds

      latest = time_value(ds.max(:occurred_at))
      window_start = (latest || now) - Muni::View.latest_window_seconds('crashes')
      normal_window = ds.where(Sequel.lit('occurred_at >= ?', window_start)).all
      {
        source_mode:                         'latest-official',
        crashes_latest_window:               normal_window.length,
        injury_latest_window:                normal_window.count { |row| truthy?(row[:injury]) },
        cyclist_or_pedestrian_latest_window: normal_window.count do |row|
          truthy?(row[:cyclist]) || truthy?(row[:pedestrian])
        end,
        trend:                               weekly_trend(ds, :occurred_at, weeks: 8, now: latest || now),
        injury_trend:                        weekly_trend(ds.where(injury: true), :occurred_at,
                                                          weeks: 8, now: latest || now),
        latest_data_lag_seconds:             latest ? [now - latest, 0].max : nil,
        latest_window_start_at:              iso_time(window_start),
        latest_occurred_at:                  iso_time(latest)
      }
    end

    def traffic_volume_widget(hall, now)
      ds = dataset(Muni::Records::TrafficVolumeDaily, hall)
      return empty_widget.merge(source_mode: 'representative-sensor') unless ds

      latest = time_value(ds.max(:observed_at))
      latest_source = latest_source_time(hall, 'traffic_volume_daily', latest)
      anchor = latest || latest_source || now
      rows = since_rows(ds, :observed_at, anchor - (30 * DAY_SECONDS))
      {
        source_mode:        'representative-sensor',
        label:              dominant_label(rows, :intersection),
        observed_sites:     distinct_count(rows, :intersection),
        total_30d:          sum_field(rows, :count),
        trend:              daily_sum_trend(ds, :observed_at, :count, days: 30, now: anchor),
        by_class:           sums_for(rows, :vehicle_class, :count, limit: 6),
        weekday_heat:       weekday_heat(rows, :observed_at, :count, hall: hall),
        latest_observed_at: iso_time(latest),
        latest_source_at:   iso_time(latest_source),
        data_lag_seconds:   lag_seconds(now, latest_source)
      }
    end

    def bicycle_counts_widget(hall, now)
      ds = dataset(Muni::Records::BicycleCount, hall)
      return empty_widget.merge(source_mode: 'representative-sensor') unless ds

      latest = time_value(ds.max(:observed_at))
      latest_source = latest_source_time(hall, 'bicycle_counts', latest)
      anchor = latest || latest_source || now
      rows = since_rows(ds, :observed_at, anchor - (30 * DAY_SECONDS))
      {
        source_mode:         'representative-sensor',
        label:               dominant_label(rows, :count_location),
        observed_sites:      distinct_count(rows, :count_location),
        total_30d:           sum_field(rows, :count),
        trend:               daily_sum_trend(ds, :observed_at, :count, days: 30, now: anchor),
        by_movement:         sums_for(rows, :movement_type, :count, limit: 5),
        by_cyclist_location: sums_for(rows, :cyclist_location, :count, limit: 5),
        hour_heat:           hour_heat(rows, :observed_at, :count, hall: hall),
        latest_observed_at:  iso_time(latest),
        latest_source_at:    iso_time(latest_source),
        data_lag_seconds:    lag_seconds(now, latest_source)
      }
    end

    def pedestrian_counts_widget(hall, now)
      ds = dataset(Muni::Records::PedestrianCountDaily, hall)
      return empty_widget.merge(source_mode: 'representative-sensor') unless ds

      latest = time_value(ds.max(:observed_at))
      latest_source = latest_source_time(hall, 'pedestrian_counts', latest)
      anchor = latest || latest_source || now
      rows = since_rows(ds, :observed_at, anchor - (30 * DAY_SECONDS))
      {
        source_mode:        'representative-sensor',
        label:              dominant_label(rows, :intersection),
        observed_sites:     distinct_count(rows, :intersection),
        total_30d:          sum_field(rows, :count),
        trend:              daily_sum_trend(ds, :observed_at, :count, days: 30, now: anchor),
        by_intersection:    sums_for(rows, :intersection, :count, limit: 5),
        weekday_heat:       weekday_heat(rows, :observed_at, :count, hall: hall),
        latest_observed_at: iso_time(latest),
        latest_source_at:   iso_time(latest_source),
        data_lag_seconds:   lag_seconds(now, latest_source)
      }
    end

    def trees_widget(hall)
      ds = dataset(Muni::Records::Tree, hall)
      return empty_widget.merge(source_mode: 'inventory') unless ds

      current_ds = current_tree_dataset(ds)
      {
        source_mode:             'inventory',
        current_tree_records:    current_ds.count,
        total_inventory_records: ds.count,
        total_trees:             ds.count,
        planting_record_count:   ds.exclude(plant_date: nil).count,
        planting_trend:          tree_planting_trend(ds, years: 12),
        species_count:           distinct_count_for_dataset(current_ds, :species_common),
        by_condition:            counts_for_dataset(ds, :condition, limit: 8),
        by_species:              counts_for_dataset(current_ds, :species_common, limit: 8),
        by_ownership:            counts_for_dataset(ds, :ownership, limit: 8),
        latest_collected_at:     iso_time(ds.max(:collected_at))
      }
    end

    def current_tree_dataset(dataset)
      dataset.where(condition: 'Tree', removal_date: nil)
    end

    def tree_planting_trend(dataset, years:)
      counts = tree_planting_year_counts(dataset)
      return [] if counts.empty?

      latest_year = counts.keys.max
      earliest_year = [counts.keys.min, latest_year - years + 1].max

      (earliest_year..latest_year).map do |year|
        { date: "#{year}-01-01", label: year.to_s, value: counts.fetch(year, 0) }
      end
    end

    def tree_planting_year_counts(dataset)
      year_expr = Sequel.function(:strftime, '%Y', :plant_date)
      rows = dataset.exclude(plant_date: nil)
                    .select(year_expr.as(:year), Sequel.function(:count, Sequel.lit('*')).as(:count))
                    .group(:year)
                    .all

      rows.each_with_object({}) do |row, out|
        year = row[:year].to_i
        next unless year.positive?

        out[year] = row[:count].to_i
      end
    end

    def dataset(record_class, hall)
      table = record_class.table_name.to_sym
      return nil unless Muni::Store.db.table_exists?(table)

      Muni::Store.db[table].where(hall: hall)
    end

    def aging_open_cases(rows, now)
      grouped = rows.group_by { |row| [presence(row[:department]), presence(row[:case_type])] }
      grouped.map { |key, group| aging_open_row(key, group, now) }
             .sort_by { |row| [-row[:count], row[:department], row[:case_type]] }
             .first(8)
    end

    def aging_open_row(key, group, now)
      department, case_type = key
      oldest = group.filter_map { |row| time_value(row[:opened_at]) }.min
      {
        department:       department || 'Unknown',
        case_type:        case_type || 'Unknown',
        count:            group.length,
        oldest_opened_at: iso_time(oldest),
        oldest_age_days:  oldest ? ((now - oldest) / 86_400).round(1) : nil
      }
    end

    def counts_for(rows, field, limit:)
      counts = rows.each_with_object(Hash.new(0)) do |row, counts|
        key = presence(row[field]) || 'Unknown'
        counts[key] += 1
      end

      counts.sort_by { |name, count| [-count, name] }
            .first(limit)
            .map { |name, count| { name: name, count: count } }
    end

    def counts_for_dataset(dataset, field, limit:)
      counts = dataset.select(field, Sequel.function(:count, Sequel.lit('*')).as(:count))
                      .group(field)
                      .all
                      .each_with_object(Hash.new(0)) do |row, out|
        out[presence(row[field]) || 'Unknown'] += row[:count].to_i
      end

      counts.sort_by { |name, count| [-count, name] }
            .first(limit)
            .map { |name, count| { name: name, count: count } }
    end

    def sums_for(rows, field, value_field, limit:)
      counts = rows.each_with_object(Hash.new(0)) do |row, counts|
        key = presence(row[field]) || 'Unknown'
        counts[key] += row[value_field].to_i
      end

      counts.sort_by { |name, count| [-count, name] }
            .first(limit)
            .map { |name, count| { name: name, count: count } }
    end

    def sum_field(rows, field)
      rows.sum { |row| row[field].to_i }
    end

    def distinct_count(rows, field)
      rows.filter_map { |row| presence(row[field]) }.uniq.length
    end

    def distinct_count_for_dataset(dataset, field)
      dataset.exclude(field => nil)
             .select(field)
             .distinct
             .all
             .count { |row| presence(row[field]) }
    end

    def dominant_label(rows, field)
      sums_for(rows, field, :count, limit: 1).first&.[](:name)
    end

    def weekday_heat(rows, time_field, value_field, hall:)
      labels = %w[Sun Mon Tue Wed Thu Fri Sat]
      counts = Array.new(7, 0)
      rows.each do |row|
        time = local_time(row[time_field], hall)
        next unless time

        counts[time.wday] += row[value_field].to_i
      end

      labels.each_with_index.map { |label, index| { label: label, count: counts[index] } }
    end

    def hour_heat(rows, time_field, value_field, hall:)
      counts = Array.new(24, 0)
      rows.each do |row|
        time = local_time(row[time_field], hall)
        next unless time

        counts[time.hour] += row[value_field].to_i
      end

      counts.each_with_index.map { |count, hour| { label: hour_label(hour), count: count } }
    end

    def since_rows(dataset, field, since)
      return [] unless dataset

      dataset.where(Sequel.lit("#{field} >= ?", since)).all
    end

    def latest_time_for_sources(*pairs)
      pairs.filter_map { |dataset, field| time_value(dataset&.max(field)) }.max
    end

    def median_duration(rows, start_field, end_field)
      median_value(duration_values(rows, start_field, end_field))
    end

    def average_duration(rows, start_field, end_field)
      durations = duration_values(rows, start_field, end_field)
      return nil if durations.empty?

      durations.sum / durations.length.to_f
    end

    def duration_values(rows, start_field, end_field)
      rows.filter_map { |row| duration_seconds(row, start_field, end_field) }.sort
    end

    def duration_seconds(row, start_field, end_field)
      start_time = time_value(row[start_field])
      end_time = time_value(row[end_field])
      return nil unless start_time && end_time && end_time >= start_time

      end_time - start_time
    end

    def median_value(values)
      values = values.compact.sort
      return nil if values.empty?

      midpoint = values.length / 2
      values.length.odd? ? values[midpoint] : ((values[midpoint - 1] + values[midpoint]) / 2.0)
    end

    def empty_widget
      { empty: true }
    end

    def presence(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end

    def truthy?(value)
      value == true || value.to_s == '1' || value.to_s.downcase == 'true'
    end

    def latest_source_time(hall, source, *fallbacks)
      source_slug = "#{hall}/#{source}"
      [Muni::Store.last_seen(source_slug), *fallbacks].compact.max
    end

    def local_time(value, hall)
      parsed = time_value(value)
      parsed && Muni::LocalTime.local_time(parsed, city: hall)
    end

    def hour_label(hour)
      return '12a' if hour.zero?
      return '12p' if hour == 12

      hour < 12 ? "#{hour}a" : "#{hour - 12}p"
    end

    def lag_seconds(now, time)
      time ? [now - time, 0].max : nil
    end

    def iso_time(value)
      time_value(value)&.utc&.iso8601
    end

    def time_value(value)
      if value.is_a?(Time)
        return Time.utc(value.year, value.month, value.day, value.hour, value.min, value.sec + value.subsec)
      end
      return value.to_time if value.respond_to?(:to_time)
      return nil if value.nil?

      Time.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
