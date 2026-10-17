require 'spec_helper'

RSpec.describe 'Meetings web endpoints' do
  def app
    Muni::Www::App
  end

  def insert_meeting(clip, attrs = {})
    Muni::Store.upsert(Muni::Records::Meeting.new(
                         external_id: "cambridge/meetings/#{clip}", hall: 'cambridge', body: 'City Council',
                         title: 'City Council - Regular Meeting', meeting_at: Time.now.utc - 86_400, clip_id: clip,
                         agenda_url: 'https://ex/agenda', video_url: 'https://ex/video',
                         ai_summary: 'Council passed the budget.', key_topics: %w[Budget Bikes],
                         people: [{ 'name' => 'Jane Doe', 'role' => 'Mayor' }],
                         collected_at: Time.now.utc, last_seen_at: Time.now.utc, **attrs
                       ))
  end

  def insert_primegov_meeting(id, attrs = {})
    Muni::Store.upsert(Muni::Records::DigestItem.new(
                         external_id:    "cambridge/primegov_meetings/#{id}",
                         hall:           'cambridge',
                         source_slug:    'cambridge/primegov_meetings',
                         source_name:    'PrimeGov Meetings',
                         source_type:    'official_record',
                         item_type:      'public_meeting',
                         section_hint:   'civic_decisions',
                         title:          'Planning Board Meeting',
                         summary:        'Documents available: Agenda',
                         category:       'public meetings',
                         url:            'https://cambridgema.primegov.com/public/portal',
                         event_start_at: Time.utc(2026, 6, 30, 22, 30),
                         published_at:   Time.utc(2026, 6, 30, 22, 30),
                         fetched_at:     Time.utc(2026, 6, 26, 12),
                         metadata:       { 'video_url' => 'https://cambridgema.v3.swagit.com/events/123' },
                         collected_at:   Time.utc(2026, 6, 26, 12),
                         **attrs
                       ))
  end

  def insert_materialized_primegov_meeting(id, attrs = {})
    Muni::Store.upsert(Muni::Records::Meeting.new(
                         external_id: "cambridge/primegov_meetings/#{id}",
                         hall: 'cambridge', source_slug: 'cambridge/primegov_meetings',
                         body: 'Planning Board', title: 'Planning Board Meeting',
                         meeting_at: Time.utc(2026, 6, 30, 22, 30),
                         video_url: 'https://cambridgema.v3.swagit.com/events/123',
                         documents: [
                           {
                             'name'   => 'Agenda',
                             'kind'   => 'agenda',
                             'format' => 'pdf',
                             'url'    => 'https://cambridgema.primegov.com/Public/CompiledDocument?meetingTemplateId=1&compileOutputType=1'
                           }
                         ],
                         collected_at: Time.utc(2026, 6, 26, 13),
                         last_seen_at: Time.utc(2026, 6, 26, 13),
                         **attrs
                       ))
  end

  before { Muni::Store.ensure_tables! }

  it 'lists meetings as JSON' do
    insert_meeting(927)
    get '/api/meetings?hall=cambridge&limit=10'
    expect(last_response).to be_ok
    rows = JSON.parse(last_response.body)
    expect(rows.first).to include('external_id' => 'cambridge/meetings/927', 'body' => 'City Council')
    expect(rows.first['ai_summary']).to eq('Council passed the budget.')
    expect(rows.first['key_topics']).to eq(%w[Budget Bikes])
  end

  it 'includes newer PrimeGov meetings in the meetings feed' do
    insert_meeting(927, meeting_at: Time.utc(2026, 1, 30, 16, 15))
    insert_primegov_meeting(2233)

    get '/api/meetings?hall=cambridge&limit=10'

    expect(last_response).to be_ok
    rows = JSON.parse(last_response.body)
    expect(rows.first).to include(
      'external_id' => 'cambridge/primegov_meetings/2233',
      'body'        => 'Planning Board',
      'meeting_at'  => '2026-06-30T22:30:00Z'
    )
    expect(rows.first['source_excerpt']).to eq('Documents available: Agenda')
    expect(rows.first['video_url']).to eq('https://cambridgema.v3.swagit.com/events/123')
  end

  it 'prefers materialized PrimeGov meeting records over digest fallbacks' do
    insert_primegov_meeting(2233)
    insert_materialized_primegov_meeting(2233, ai_summary: 'Agenda preview', source_text_kind: 'agenda')

    get '/api/meetings?hall=cambridge&limit=10'

    expect(last_response).to be_ok
    rows = JSON.parse(last_response.body)
    matching = rows.select { |row| row['external_id'] == 'cambridge/primegov_meetings/2233' }
    expect(matching.length).to eq(1)
    expect(matching.first['ai_summary']).to eq('Agenda preview')
    expect(matching.first['documents']).to include(include('kind' => 'agenda'))
  end

  it 'returns a single meeting by clip id' do
    insert_meeting(927)
    get '/api/meetings/927?hall=cambridge'
    expect(last_response).to be_ok
    expect(JSON.parse(last_response.body)).to include('clip_id' => 927, 'video_url' => 'https://ex/video')
  end

  it '404s for an unknown clip id' do
    get '/api/meetings/123456?hall=cambridge'
    expect(last_response.status).to eq(404)
  end

  it 'renders the meetings page with the grid component and rail link' do
    get '/meetings?hall=cambridge'
    expect(last_response).to be_ok
    expect(last_response.body).to include('muniMeetings(')
    expect(last_response.body).to include('data-icon="landmark"')
    expect(last_response.body).to include('summaryKindLabel(activeMeeting)')
    pending_copy = 'Summary refreshes when official agenda, minutes, or final actions are available.'
    expect(last_response.body).to include(pending_copy)
  end
end
