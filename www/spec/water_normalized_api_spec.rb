require 'spec_helper'

RSpec.describe 'Normalized Charles River API contracts' do
  def app = Muni::Www::App

  before do
    Muni::Store.ensure_tables!
    allow(Muni::Water).to receive(:enabled?).and_return(true)
  end

  def publish(*records)
    Muni::Water::EvidenceWriter.new.call(records)
  end

  def sensor(id, hour, value)
    { external_id: id, source_slug: 'water/charles/epa_buoy', waterbody: 'charles',
      kind: 'sensor', location_id: 'epa-buoy', reach_id: '5', parameter: 'temperature',
      value: value, unit: '°C', method: 'EPA buoy sensor', segment: 'epa-2026', status: 'provisional',
      observed_at: Time.utc(2026, 10, 16, hour), fetched_at: Time.now.utc,
      source_url: Muni::Water::Catalog::BUOY, parser_version: Muni::Water::VERSION,
      raw: { 'temperature' => value }, payload: {} }
  end

  def laboratory(id: 1, value: 42, date: Time.utc(2026, 7, 21))
    adapter = Muni::Water::Adapters::CrwaLaboratory.new(id: 'crwa_laboratory')
    raw = { 'FID' => id, 'GlobalID' => "publication-#{id}", 'Site_ID' => '763S',
            'Date_Collected' => date.to_i * 1000, 'Reporting_Result' => value, 'Unit_Abbreviation' => 'cfu/100mL' }
    adapter.send(:sample, raw)
  end

  def routine_sample(id: 'routine', role: 'Sample-Routine', value: '63', time: '06:15')
    adapter = Muni::Water::Adapters::Wqp.new(id: 'wqp')
    raw = { 'Location_Identifier' => 'CRWA-763S', 'Activity_StartDate' => '2025-12-09',
            'Activity_StartTime' => time, 'Activity_StartTimeZone' => 'EST', 'Activity_TypeCode' => role,
            'Activity_ActivityIdentifier' => "CRWA-#{id}", 'Result_MeasureIdentifier' => id,
            'Result_Measure' => value, 'Result_MeasureUnit' => 'MPN/100mL',
            'Result_MeasureStatusIdentifier' => 'Accepted' }
    adapter.send(:sample, raw)
  end

  def retain_legacy_publication(record)
    legacy = record.except(:observed_date, :time_precision, :normalization_version, :publication_group_id)
    legacy[:observed_at] = Time.at(record[:raw]['Date_Collected'] / 1000.0).utc
    legacy[:payload] = legacy[:payload].except(:normalization_version, :publication_group_id, :observed_date)
    Muni::Water::Storage.db[:water_revisions].insert(evidence_id: record[:external_id], version: 1,
                                                     fingerprint: 'legacy-fixture',
                                                     record: Muni::Water.json(legacy), detected_at: Time.now.utc)
  end

  it 'exports one revision snapshot despite corrections and newly arriving observations between pages' do
    publish(sensor('a', 14, 10), sensor('b', 13, 20), sensor('c', 12, 30))
    filters = { source: 'water/charles/epa_buoy', presentation: 'observations', limit: 1 }
    get '/api/water/charles/export.csv', filters
    expect(last_response.status).to eq(200)
    first = CSV.parse(last_response.body, headers: true)
    expect(first.map { |row| row['external_id'] }).to eq(['a'])
    cursor = last_response.headers['x-next-cursor']
    cutoff = last_response.headers['x-revision-cutoff']
    expect(cursor).not_to be_empty

    publish(sensor('b', 13, 999), sensor('new', 15, 50))
    get '/api/water/charles/export.csv', filters.merge(cursor: cursor)
    expect(last_response.status).to eq(200)
    second = CSV.parse(last_response.body, headers: true)
    expect(second.map { |row| row['external_id'] }).to eq(['b'])
    expect(second.first['value'].to_f).to eq(20)
    expect(last_response.headers['x-revision-cutoff']).to eq(cutoff)
    cursor = last_response.headers['x-next-cursor']

    get '/api/water/charles/export.csv', filters.merge(cursor: cursor)
    expect(CSV.parse(last_response.body, headers: true).map { |row| row['external_id'] }).to eq(['c'])
    expect(last_response.headers['x-next-cursor']).to be_empty
  end

  it 'applies exact timestamp bounds equally to live records and a revision snapshot' do
    publish(sensor('before', 13, 10), sensor('inside', 14, 20), sensor('after', 15, 30))
    filters = { source: 'water/charles/epa_buoy', from: '2026-10-16T13:30:00Z', to: '2026-10-16T14:30:00Z' }
    [filters, filters.merge(cursor: 'start')].each do |params|
      get '/api/water/charles/records', params
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)['records'].map { |row| row['external_id'] }).to eq(['inside'])
    end
  end

  it 'keeps withdrawn and ambiguous notices inspectable while excluding them from card primaries and counts' do
    %w[published retracted needs_review].each_with_index do |status, index|
      publish(sensor(status, 12 + index, 0.14).merge(kind: 'discharge', status: status,
                                                     source_slug: 'water/charles/cambridge_cso', location_id: 'CAM005',
                                                     unit: 'million gallons',
                                                     payload: { countable: status == 'published' }))
    end
    get '/api/water/charles/metrics'
    primary = JSON.parse(last_response.body)['metrics'].filter_map { |metric| metric['primary'] }
    expect(primary.select { |row| row['kind'] == 'discharge' }.map { |row| row['external_id'] }).to eq(['published'])
    get '/api/water/charles/records', kinds: 'discharge'
    records = JSON.parse(last_response.body)['records'].to_h { |row| [row['status'], row] }
    %w[retracted needs_review].each do |status|
      expect(records.fetch(status)['eligibility']).to include('display' => true, 'primary' => false,
                                                              'calculation' => false)
    end
    get '/api/water/charles/trends', source: 'water/charles/cambridge_cso', from: '2026-10-16', to: '2026-10-17'
    expect(JSON.parse(last_response.body)['record_count']).to eq(1)
  end

  it 'filters date-only samples by the published date and exposes stable publication group membership' do
    first = laboratory(id: 6237)
    second = laboratory(id: 82_943)
    other = laboratory(id: 3, value: 100)
    publish(first, second, other)
    filters = { source: 'water/charles/crwa_laboratory', from: '2026-07-21', to: '2026-07-22',
                presentation: 'observations' }
    get '/api/water/charles/records', filters
    body = JSON.parse(last_response.body)
    expect(last_response.status).to eq(200)
    expect(body['total']).to eq(2)
    grouped = body['records'].find { |row| row['value'] == 42 }
    ids = [first[:external_id], second[:external_id]].sort
    expect(grouped['external_id']).to eq(ids.first)
    expect(grouped['publication_count']).to eq(2)
    expect(grouped['publication_ids']).to eq(ids)
    expect(grouped.values_at('observed_at', 'observed_date', 'time_precision')).to eq([nil, '2026-07-21', 'date'])

    get '/api/water/charles/records', filters.merge(from: '2026-07-20', to: '2026-07-21')
    expect(JSON.parse(last_response.body)['total']).to eq(0)
    get '/api/water/charles/records', filters.merge(presentation: 'publications')
    expect(JSON.parse(last_response.body)['total']).to eq(3)
  end

  it 'uses the same primary lab result in metrics and map data while preserving newer qualified evidence' do
    routine = routine_sample
    qc = routine_sample(id: 'qc', role: 'Quality Control Sample-Field Replicate', value: '74', time: '06:20')
    qualified = laboratory
    publish(routine, qc, qualified)
    get '/api/water/charles/metrics'
    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    primary_ids = body['metrics'].filter_map { |metric| metric.dig('primary', 'external_id') }
    expect(primary_ids).to include(routine[:external_id], qualified[:external_id])
    expect(primary_ids).not_to include(qc[:external_id])
    expect(body['latest'].map { |row| row['external_id'] }).to match_array(primary_ids)
    newer = body['metrics'].find { |metric| metric.dig('primary', 'external_id') == qualified[:external_id] }
    expect(newer.dig('qualified_latest', 'observed_date')).to eq('2026-07-21')
    expect(newer.dig('confirmed_routine', 'external_id')).to eq(routine[:external_id])
    expect(newer.dig('confirmed_routine', 'unit')).to eq('MPN/100mL')
    expect(newer.dig('primary', 'unit')).to eq('cfu/100mL')
  end

  it 'rejects malformed cursor shapes without raising a server error' do
    [[], nil, 42, 'invalid'].each do |value|
      cursor = Base64.urlsafe_encode64(JSON.generate(value))
      get '/api/water/charles/records', cursor: cursor
      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body)['error']).to eq('Invalid export cursor')
    end
  end

  it 'keeps complete duplicate membership and distinct newest-date candidates without a row cap' do
    publish(*(1..151).map { |id| laboratory(id: id) }, laboratory(id: 999, value: 100))
    get '/api/water/charles/metrics'
    rows = JSON.parse(last_response.body)['snapshots']['samples']
    duplicate = rows.find { |row| row['value'] == 42 }
    expect(rows.map { |row| row['value'] }).to contain_exactly(42, 100)
    expect(duplicate['publication_count']).to eq(151)
    expect(duplicate['publication_ids'].length).to eq(151)
    expect(rows.map { |row| row['selection_status'] }.uniq).to eq(['multiple_distinct_results'])
    expect(duplicate['selection_candidates'].map { |row| row['value'] }).to contain_exactly(42, 100)
    get "/api/water/charles/evidence/#{duplicate['external_id']}", revision: duplicate['revision_id'],
                                                                   cutoff:   duplicate['revision_cutoff']
    expect(JSON.parse(last_response.body)['record']['publication_count']).to eq(151)
  end

  it 'lists all equally recent routine companions instead of choosing a result by publication identifier' do
    publish(routine_sample(id: 'a', value: '63'), routine_sample(id: 'b', value: '90'), laboratory)
    get '/api/water/charles/metrics'
    metric = JSON.parse(last_response.body)['metrics'].find { |row| row['qualified_latest'] }
    expect(metric['confirmed_routine']).to be_nil
    expect(metric['confirmed_routine_candidates'].map { |row| row['value'] }).to contain_exactly(63, 90)
  end

  it 'preserves cross-source qualifications in filtered records and exact-revision detail' do
    date = Time.utc(2025, 12, 9)
    publish(routine_sample, laboratory(value: 63, date: date))
    get '/api/water/charles/metrics'
    row = JSON.parse(last_response.body)['latest'].find { |record| record['source_slug'].end_with?('/wqp') }
    expect(row['eligibility']['reasons']).to include('cross_source_unit_conflict')
    get '/api/water/charles/records', source: 'water/charles/wqp'
    expect(JSON.parse(last_response.body)['records'].first['eligibility']).to eq(row['eligibility'])
    publish(laboratory(value: 64, date: date))
    get "/api/water/charles/evidence/#{row['external_id']}", revision: row['revision_id'],
                                                             cutoff:   row['revision_cutoff']
    expect(JSON.parse(last_response.body)['record']['eligibility']).to eq(row['eligibility'])
    get "/api/water/charles/evidence/#{row['external_id']}"
    reasons = JSON.parse(last_response.body)['record']['eligibility']['reasons']
    expect(reasons).not_to include('cross_source_unit_conflict')
  end

  it 'keeps source-filtered CSV qualifications at the export cutoff when another feed is corrected' do
    date = Time.utc(2025, 12, 9)
    publish(routine_sample(id: 'a'), routine_sample(id: 'b'), laboratory(value: 63, date: date))
    filters = { source: 'water/charles/wqp', presentation: 'observations', limit: 1 }
    get '/api/water/charles/export.csv', filters
    cursor = last_response.headers['x-next-cursor']
    first = CSV.parse(last_response.body, headers: true).first
    expect(JSON.parse(first['eligibility'])['reasons']).to include('cross_source_unit_conflict')
    publish(laboratory(value: 64, date: date))
    get '/api/water/charles/export.csv', filters.merge(cursor: cursor)
    second = CSV.parse(last_response.body, headers: true).first
    expect(second['revision_cutoff']).to eq(first['revision_cutoff'])
    expect(JSON.parse(second['eligibility'])['reasons']).to include('cross_source_unit_conflict')
    get '/api/water/charles/export.csv', filters
    current = CSV.parse(last_response.body, headers: true).first
    expect(JSON.parse(current['eligibility'])['reasons']).not_to include('cross_source_unit_conflict')
  end

  it 'counts date-only publications on their stated date and isolates deployment segments in observation charts' do
    publish(laboratory, sensor('old-segment', 14, 1).merge(segment: 'old'), sensor('new-segment', 14, 99))
    get '/api/water/charles/trends', source: 'water/charles/crwa_laboratory', from: '2026-07-21', to: '2026-07-22'
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)['series'].first['points'].first['value']).to eq(1)
    get '/api/water/charles/records', source: 'water/charles/epa_buoy', segment: 'old'
    expect(JSON.parse(last_response.body)['records'].map { |row| row['external_id'] }).to eq(['old-segment'])
  end

  it 'opens the exact revision shown on a card after a publisher correction arrives' do
    publish(sensor('card', 14, 10))
    get '/api/water/charles/metrics'
    row = JSON.parse(last_response.body)['metrics'].first['primary']
    expect(row['revision_id']).to be_a(Integer)
    publish(sensor('card', 14, 99))
    get '/api/water/charles/evidence/card', revision: row['revision_id'], cutoff: row['revision_cutoff']
    detail = JSON.parse(last_response.body)
    expect(detail['record']).to include('value' => 10, 'revision_id' => row['revision_id'])
    expect(detail['revision_cutoff']).to eq(row['revision_cutoff'])
    expect(detail['revisions'].map { |revision| revision['record']['value'] }).to eq([10, 99])
    get '/api/water/charles/evidence/card'
    expect(JSON.parse(last_response.body)['record']['value']).to eq(99)
  end

  it 'includes revision, normalization and policy identifiers on fixed-cutoff exports' do
    publish(sensor('exported', 14, 10))
    get '/api/water/charles/export.csv', source: 'water/charles/epa_buoy', limit: 1
    row = CSV.parse(last_response.body, headers: true).first
    expect(row['revision_id'].to_i).to be_positive
    expect(row['revision_cutoff']).to eq(last_response.headers['x-revision-cutoff'])
    expect(row['normalization_version']).to eq(Muni::Water::Normalization::VERSION)
    expect(row['policy_version']).to eq(Muni::Water::DailySummaries::POLICY_VERSION)
    get '/api/water/charles/evidence/another-record', revision: row['revision_id']
    expect(last_response.status).to eq(400)
  end

  it 'returns only the immutable before and after inputs of an older publication-change signal' do
    publish(sensor('changed', 14, 10))
    publish(sensor('changed', 14, 20))
    Muni::Water::Signals.new.recalculate(slug: 'water/charles/epa_buoy', dirty: [], revision_range: [2, 2])
    signal = Muni::Water::Storage.db[:water_signal_versions].where(kind: 'published_record_changed').first
    publish(sensor('changed', 14, 30))

    get "/api/water/charles/signals/#{signal[:id]}/evidence"

    body = JSON.parse(last_response.body)
    expect(last_response.status).to eq(200)
    expect(body['records'].map { |row| row['revision_id'] }).to eq([1, 2])
    expect(body['records'].map { |row| row['record']['value'] }).to eq([10, 20])
    expect(body.values_at('total', 'revision_cutoff')).to eq([2, 2])
  end

  it 'reconstructs legacy publication membership at the cutoff while normalization and corrections arrive' do
    first = laboratory(id: 1)
    second = laboratory(id: 2)
    old_revision = retain_legacy_publication(first)
    cutoff = retain_legacy_publication(second)
    ids = [first[:external_id], second[:external_id]].sort
    publish(first)
    mixed_cutoff = Muni::Water::Storage.db[:water_revisions].max(:id)
    publish(laboratory(id: 2, value: 99))

    [cutoff, mixed_cutoff].each do |boundary|
      get "/api/water/charles/evidence/#{first[:external_id]}", revision: old_revision, cutoff: boundary
      record = JSON.parse(last_response.body)['record']
      expect(record.values_at('publication_count', 'publication_ids')).to eq([2, ids])
    end
    get "/api/water/charles/evidence/#{first[:external_id]}"
    expect(JSON.parse(last_response.body)['record']['publication_ids']).to eq([first[:external_id]])
  end
end
