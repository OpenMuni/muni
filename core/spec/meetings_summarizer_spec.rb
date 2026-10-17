require 'spec_helper'

RSpec.describe Muni::Meetings::Summarizer do
  before { Muni::Store.ensure_tables! }

  def insert_meeting(clip, summary: nil, **attrs)
    Muni::Records::Meeting.new(
      external_id: "cambridge/meetings/#{clip}", hall: 'cambridge', body: 'City Council',
      title: 'City Council - Regular Meeting', meeting_at: Time.now.utc - 86_400, clip_id: clip,
      agenda_url: 'https://ex/agenda', ai_summary: summary,
      collected_at: Time.now.utc, last_seen_at: Time.now.utc, **attrs
    ).tap { |m| Muni::Store.upsert(m) }
  end

  def client(configured: true)
    instance_double(
      Muni::AnthropicClient,
      configured?: configured, model: 'claude-sonnet-4-6',
      complete: { text:  '{"summary":"Council passed the budget.","key_topics":["Budget","Bikes"]}',
                  model: 'claude-sonnet-4-6' }
    )
  end

  def meeting_document(kind, url: "https://ex/primegov-#{kind}.pdf")
    {
      'name'   => kind.split('_').map(&:capitalize).join(' '),
      'kind'   => kind,
      'format' => 'pdf',
      'url'    => url
    }
  end

  it 'summarizes meetings missing a summary and persists the result' do
    insert_meeting(1)
    allow(described_class).to receive(:source_text).and_return(['Agenda text ' * 50, 'agenda'])

    tally = described_class.summarize_pending(hall: 'cambridge', limit: 5, client: client)

    expect(tally[:summarized]).to eq(1)
    row = Muni::Store.find(Muni::Records::Meeting, 'cambridge/meetings/1')
    expect(row.ai_summary).to eq('Council passed the budget.')
    expect(row.key_topics).to eq(%w[Budget Bikes])
    expect(row.source_text_kind).to eq('agenda')
    expect(row.summary_model).to eq('claude-sonnet-4-6')
  end

  it 'leaves already-summarized meetings alone unless forced' do
    insert_meeting(2, summary: 'existing summary', source_text_kind: 'agenda')
    allow(described_class).to receive(:source_text).and_return(['Agenda text ' * 50, 'agenda'])

    tally = described_class.summarize_pending(hall: 'cambridge', limit: 5, client: client)

    expect(tally[:candidates]).to eq(0)
    expect(Muni::Store.find(Muni::Records::Meeting, 'cambridge/meetings/2').ai_summary).to eq('existing summary')
  end

  it 'force re-summarizes existing summaries' do
    insert_meeting(3, summary: 'old summary')
    allow(described_class).to receive(:source_text).and_return(['Agenda text ' * 50, 'agenda'])

    described_class.summarize_pending(hall: 'cambridge', limit: 5, force: true, client: client)

    expect(Muni::Store.find(Muni::Records::Meeting,
                            'cambridge/meetings/3').ai_summary).to eq('Council passed the budget.')
  end

  it 'summarizes agenda-only PrimeGov documents as an agenda preview' do
    insert_meeting(
      6,
      clip_id:    nil,
      agenda_url: nil,
      documents:  [meeting_document('agenda', url: 'https://ex/primegov-agenda.pdf')]
    )
    allow(described_class).to receive(:pdf_text)
      .with('https://ex/primegov-agenda.pdf')
      .and_return('Agenda text ' * 50)

    tally = described_class.summarize_pending(hall: 'cambridge', limit: 5, client: client)
    row = Muni::Store.find(Muni::Records::Meeting, 'cambridge/meetings/6')

    expect(tally[:summarized]).to eq(1)
    expect(row.ai_summary).to eq('Council passed the budget.')
    expect(row.source_text_kind).to eq('agenda')
  end

  it 'upgrades an agenda preview when final actions are published' do
    insert_meeting(
      7,
      summary:          'Agenda preview',
      source_text_kind: 'agenda',
      clip_id:          nil,
      agenda_url:       nil,
      minutes_url:      'https://ex/primegov-actions.pdf',
      documents:        [
        meeting_document('agenda', url: 'https://ex/primegov-agenda.pdf'),
        meeting_document('final_actions', url: 'https://ex/primegov-actions.pdf')
      ]
    )
    allow(described_class).to receive(:pdf_text)
      .with('https://ex/primegov-actions.pdf')
      .and_return('Final actions text ' * 50)

    tally = described_class.summarize_pending(hall: 'cambridge', limit: 5, client: client)
    row = Muni::Store.find(Muni::Records::Meeting, 'cambridge/meetings/7')

    expect(tally[:summarized]).to eq(1)
    expect(row.ai_summary).to eq('Council passed the budget.')
    expect(row.source_text_kind).to eq('final_actions')
  end

  it 'does not regenerate summaries that already use the best available source' do
    meeting = insert_meeting(
      8,
      summary:          'Minutes summary',
      source_text_kind: 'minutes',
      clip_id:          nil,
      agenda_url:       nil,
      documents:        [meeting_document('minutes', url: 'https://ex/primegov-minutes.pdf')]
    )
    ai_client = client
    allow(ai_client).to receive(:complete)

    tally = described_class.summarize_pending(hall: 'cambridge', limit: 5, client: ai_client)

    expect(tally[:candidates]).to eq(0)
    expect(ai_client).not_to have_received(:complete)
    expect(Muni::Store.find(Muni::Records::Meeting, meeting.external_id).ai_summary).to eq('Minutes summary')
  end

  it 'skips meetings with no usable source text (stays retryable)' do
    insert_meeting(4)
    allow(described_class).to receive(:source_text).and_return([nil, nil])

    tally = described_class.summarize_pending(hall: 'cambridge', limit: 5, client: client)

    expect(tally).to include(summarized: 0, skipped: 1)
    expect(Muni::Store.find(Muni::Records::Meeting, 'cambridge/meetings/4').ai_summary).to be_nil
  end

  it 'is a no-op when the AI client is not configured' do
    insert_meeting(5)
    tally = described_class.summarize_pending(hall: 'cambridge', limit: 5, client: client(configured: false))
    expect(tally[:error]).to eq('AI unavailable')
  end

  describe '.strip_vtt' do
    it 'turns a WebVTT caption track into a clean transcript' do
      vtt = <<~VTT
        WEBVTT

        1
        00:00:01.000 --> 00:00:03.000
        <v Mayor>Good evening, the meeting is called to order.

        2
        00:00:03.000 --> 00:00:05.000
        Good evening, the meeting is called to order.
        The first item is the budget.
      VTT
      expect(described_class.strip_vtt(vtt))
        .to eq('Good evening, the meeting is called to order. The first item is the budget.')
    end

    it 'returns nil for an empty or header-only VTT' do
      expect(described_class.strip_vtt("WEBVTT\n\n")).to be_nil
      expect(described_class.strip_vtt('')).to be_nil
      expect(described_class.strip_vtt(nil)).to be_nil
    end
  end
end
