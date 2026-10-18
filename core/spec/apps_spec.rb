require 'spec_helper'

RSpec.describe Muni::Apps do
  before do
    Muni::Store.ensure_tables!
    Muni::Store.db[:digest_items].delete
  end

  def upsert_digest_item(external_id, attrs = {})
    Muni::Store.upsert(Muni::Records::DigestItem.new(
                         external_id: external_id,
                         hall:        'cambridge',
                         source_slug: 'cambridge/city_calendar',
                         source_name: 'City Calendar',
                         source_type: 'event_listing',
                         title:       'Council meeting',
                         summary:     'Agenda review',
                         fetched_at:  Time.now.utc,
                         confidence:  0.9,
                         **attrs
                       ))
  end

  it 'lists only available public apps' do
    apps = described_class.manifest(
      hall:       'cambridge',
      digest:     { 'cards' => [{ 'id' => 'digest-1' }] },
      reminders:  [{ 'id' => 'reminder-1' }],
      calendar:   [{ 'id' => 'event-1' }],
      health:     { 'status' => 'ok' },
      categories: [{ 'row_count' => 3 }]
    )

    expect(apps.map { |app| app['id'] }).to eq(%w[map transit digest reminders calendar health])
    expect(apps.find { |app| app['id'] == 'transit' }['surface']).to eq('primary')
    expect(apps.find { |app| app['id'] == 'map' }['count']).to eq(3)
  end

  it 'marks meetings unavailable for Boston' do
    apps = described_class.manifest(hall: 'boston', calendar: [{ 'id' => 'event-1' }])

    expect(apps.find { |app| app['id'] == 'calendar' }['status']).to eq('unavailable')
  end

  it 'derives health from existing source data' do
    health = described_class.health(
      source_freshness: {
        counts:     { 'cambridge/service_requests' => 2 },
        latest_run: { 'cambridge/service_requests' => { error: nil } }
      },
      dashboard:        {
        widgets: {
          service_requests: { open_cases: 1, stale_open_cases: 0, opened_last_7d: 2 },
          safety:           { crime_reports_30d: 1, dispatch_calls_30d: 2, recent_crashes_30d: 0 }
        }
      }
    )

    expect(health).to include('status' => 'ok')
    expect(health.dig('sources', 'record_count')).to eq(2)
    expect(health.dig('city_pulse', 'safety_items_30d')).to eq(3)
  end

  it 'derives reminders from the public digest' do
    upsert_digest_item(
      'reminder/street-cleaning',
      source_slug:  'cambridge/practical_services',
      source_name:  'Street Cleaning',
      item_type:    'service_reminder',
      section_hint: 'practical_reminders',
      title:        'Street cleaning moved',
      published_at: Time.now.utc,
      tags:         ['reminder']
    )

    expect(described_class.reminders(hall: 'cambridge').map { |row| row['id'] })
      .to include('reminder/street-cleaning')
  end

  it 'derives calendar events from the public digest' do
    upsert_digest_item(
      'calendar/council',
      item_type:      'public_meeting',
      section_hint:   'civic_decisions',
      event_start_at: Time.now.utc + 86_400,
      tags:           ['meeting']
    )

    expect(described_class.calendar(hall: 'cambridge').map { |row| row['id'] })
      .to include('calendar/council')
  end
end
