require 'spec_helper'

RSpec.describe Muni::Meetings::PrimegovMaterializer do
  before { Muni::Store.ensure_tables! }

  def insert_primegov_digest(id, attrs = {})
    Muni::Store.upsert(Muni::Records::DigestItem.new(
                         external_id:    "cambridge/primegov_meetings/#{id}",
                         hall:           'cambridge',
                         source_slug:    'cambridge/primegov_meetings',
                         source_name:    'PrimeGov Meetings',
                         source_type:    'official_record',
                         item_type:      'public_meeting',
                         title:          'Regular City Council Meeting',
                         summary:        'Documents available: Agenda',
                         category:       'public meetings',
                         url:            'https://cambridgema.v3.swagit.com/events/123',
                         event_start_at: Time.utc(2026, 6, 30, 21, 30),
                         published_at:   Time.utc(2026, 6, 30, 21, 30),
                         metadata:       {
                           'video_url' => 'https://cambridgema.v3.swagit.com/events/123',
                           'documents' => [primegov_document('agenda', template_id: 1)]
                         },
                         collected_at:   Time.utc(2026, 6, 26, 12),
                         **attrs
                       ))
  end

  def primegov_document(kind, template_id:, published_at: '2026-06-25T14:36:40Z')
    {
      'name'         => kind.split('_').map(&:capitalize).join(' '),
      'kind'         => kind,
      'format'       => 'pdf',
      'url'          => primegov_document_url(template_id),
      'published_at' => published_at
    }
  end

  def primegov_document_url(template_id)
    "https://cambridgema.primegov.com/Public/CompiledDocument?meetingTemplateId=#{template_id}&compileOutputType=1"
  end

  it 'materializes PrimeGov digest rows into meeting records' do
    insert_primegov_digest(2233)

    tally = described_class.materialize!(hall: 'cambridge', limit: 10, now: Time.utc(2026, 6, 26, 13))
    meeting = Muni::Store.find(Muni::Records::Meeting, 'cambridge/primegov_meetings/2233')

    expect(tally).to eq(candidates: 1, upserted: 1)
    expect(meeting.source_slug).to eq('cambridge/primegov_meetings')
    expect(meeting.body).to eq('City Council')
    expect(meeting.agenda_url).to include('/Public/CompiledDocument?meetingTemplateId=1')
    expect(meeting.documents.first['kind']).to eq('agenda')
  end

  it 'refreshes documents without erasing an existing summary' do
    insert_primegov_digest(2233)
    described_class.materialize!(hall: 'cambridge', limit: 10, now: Time.utc(2026, 6, 26, 13))
    meeting = Muni::Store.find(Muni::Records::Meeting, 'cambridge/primegov_meetings/2233')
    meeting.ai_summary = 'Agenda preview'
    meeting.source_text_kind = 'agenda'
    Muni::Store.upsert(meeting)

    insert_primegov_digest(
      2233,
      metadata: {
        'video_url' => 'https://cambridgema.v3.swagit.com/events/123',
        'documents' => [primegov_document('minutes', template_id: 2, published_at: '2026-07-10T14:36:40Z')]
      }
    )

    described_class.materialize!(hall: 'cambridge', limit: 10, now: Time.utc(2026, 7, 10, 15))
    refreshed = Muni::Store.find(Muni::Records::Meeting, 'cambridge/primegov_meetings/2233')

    expect(refreshed.ai_summary).to eq('Agenda preview')
    expect(refreshed.source_text_kind).to eq('agenda')
    expect(refreshed.documents.first['kind']).to eq('minutes')
    expect(refreshed.minutes_url).to include('/Public/CompiledDocument?meetingTemplateId=2')
  end

  it 'runs from the scheduled PrimeGov meeting-record beat' do
    insert_primegov_digest(2233)
    beat = Muni::Registry.beat('cambridge/primegov_meeting_records')

    result = beat.new.run!

    expect(result[:error]).to be_nil
    expect(result[:rows_upserted]).to eq(1)
    expect(Muni::Store.find(Muni::Records::Meeting, 'cambridge/primegov_meetings/2233')).not_to be_nil
  end
end
