require 'spec_helper'
require 'nokogiri'

RSpec.describe Cambridge::Meetings do
  # Minimal mirror of the Granicus ViewPublisher table: a row-header name cell,
  # a Date cell + Duration cell (keyed by their `headers` attribute), and
  # Agenda/Minutes/MediaPlayer links carrying ?clip_id=N.
  let(:fixture) do
    <<~HTML
      <table>
        <tr>
          <td scope="row">Mar 13, 2025 6:00 PM - Board of Zoning Appeal - Hearing</td>
          <td headers="Date r1">March 13, 2025 - 6:00 PM</td>
          <td headers="Duration r1">00h 55m</td>
          <td><a href="//cambridgema.granicus.com/AgendaViewer.php?view_id=1&clip_id=950">Agenda</a></td>
        </tr>
        <tr>
          <td scope="row">Jan 6, 2025 5:30 PM - City Council - Regular Meeting</td>
          <td headers="Date r2">January 6, 2025 - 5:30 PM</td>
          <td headers="Duration r2">03h 13m</td>
          <td><a href="//cambridgema.granicus.com/AgendaViewer.php?view_id=1&clip_id=927">Agenda</a></td>
          <td><a href="//cambridgema.granicus.com/MinutesViewer.php?view_id=1&clip_id=927&doc_id=abc">Minutes</a></td>
          <td><a href="//cambridgema.granicus.com/MediaPlayer.php?view_id=1&clip_id=927">Video</a></td>
        </tr>
        <tr>
          <td scope="row">Apr 2, 2025 6:30 PM - Planning Board - Meeting</td>
          <td headers="Date r3">April 2, 2025 - 6:30 PM</td>
          <td><a href="//cambridgema.granicus.com/AgendaViewer.php?view_id=1&clip_id=960">Agenda</a></td>
        </tr>
        <tr>
          <td scope="row">Jan 9, 2023 5:30 PM - City Council - Regular Meeting</td>
          <td headers="Date r4">January 9, 2023 - 5:30 PM</td>
          <td><a href="//cambridgema.granicus.com/AgendaViewer.php?view_id=1&clip_id=500">Agenda</a></td>
        </tr>
      </table>
    HTML
  end

  def source
    src = described_class.new
    roster = [{ 'name' => 'Jane Doe', 'role' => 'Mayor', 'email' => 'jane@cambridgema.gov' }]
    allow(src).to receive_messages(granicus_doc: Nokogiri::HTML5.parse(fixture), council_roster: roster)
    src
  end

  it 'parses whitelisted bodies from 2025 onward, newest first' do
    records = source.pull(limit: 10)
    expect(records.map(&:body)).to eq(['Board of Zoning Appeal', 'City Council'])
  end

  it 'excludes non-whitelisted bodies and meetings before the floor' do
    clips = source.pull(limit: 10).map(&:clip_id)
    expect(clips).to contain_exactly(950, 927) # Planning Board (960) + 2023 (500) dropped
  end

  it 'extracts clip-keyed external_id and document links' do
    council = source.pull(limit: 10).find { |r| r.body == 'City Council' }
    expect(council.external_id).to eq('cambridge/meetings/927')
    expect(council.meeting_at.year).to eq(2025)
    expect(council.duration).to eq('03h 13m')
    expect(council.agenda_url).to eq('https://cambridgema.granicus.com/AgendaViewer.php?view_id=1&clip_id=927')
    expect(council.minutes_url).to include('MinutesViewer.php?view_id=1&clip_id=927')
    expect(council.video_url).to eq('https://cambridgema.granicus.com/MediaPlayer.php?view_id=1&clip_id=927')
    expect(council.transcript_url).to eq('https://cambridgema.granicus.com/videos/927/captions.vtt')
  end

  it 'attaches the council roster only to City Council meetings' do
    records = source.pull(limit: 10)
    council = records.find { |r| r.body == 'City Council' }
    bza = records.find { |r| r.body == 'Board of Zoning Appeal' }
    expect(council.people.first['role']).to eq('Mayor')
    expect(bza.people).to eq([])
  end

  it 'honors an explicit since floor' do
    records = source.pull(since: Time.utc(2025, 2, 1), limit: 10)
    expect(records.map(&:clip_id)).to eq([950]) # Jan 6 City Council now excluded
  end
end
