require 'spec_helper'

RSpec.describe Muni::ServiceRequestPolicy do
  let(:now) { Time.utc(2026, 8, 23, 12) }

  it 'maps source-specific statuses onto the shared 311 lifecycle palette' do
    recent = now - 3_600

    expect(described_class.enrich({ status: 'Open', opened_at: recent }, now: now))
      .to include(display_status: 'open', lifecycle_status: 'open')
    expect(described_class.enrich({ status: 'In Progress', updated_at: recent }, now: now))
      .to include(display_status: 'in progress', lifecycle_status: 'acknowledged')
    expect(described_class.enrich({ status: 'Needs Reallocation', updated_at: recent }, now: now))
      .to include(display_status: 'needs reallocation', lifecycle_status: 'pending')
    expect(described_class.enrich({ status: 'Apply', updated_at: recent }, now: now))
      .to include(display_status: 'apply', lifecycle_status: 'pending')
    expect(described_class.enrich({ status: 'Closed', closed_at: recent }, now: now))
      .to include(display_status: 'closed', lifecycle_status: 'closed')
  end

  it 'marks acknowledged work stale using the same rule for every Hall' do
    stale = now - described_class::STALE_ACK_SECONDS - 1

    expect(described_class.enrich({ status: 'In Progress', updated_at: stale }, now: now))
      .to include(display_status: 'stale', lifecycle_status: 'stale')
  end

  it 'gives unknown active upstream statuses the visible pending fallback' do
    result = described_class.enrich({ status: 'Unexpected Workflow State', opened_at: now }, now: now)

    expect(result).to include(display_status: 'unexpected workflow state', lifecycle_status: 'pending')
  end

  it 'keeps map eligibility tied to authoritative status and report date' do
    recent = now - (24 * 60 * 60)
    old = now - (31 * 24 * 60 * 60)
    expect(described_class.map_eligible?({ status: 'Open', opened_at: recent }, now: now)).to be(true)
    expect(described_class.map_eligible?({ status: 'In Progress', opened_at: recent }, now: now)).to be(true)
    expect(described_class.map_eligible?({ status: 'Closed', opened_at: recent }, now: now)).to be(false)
    expect(described_class.map_eligible?({ status: 'Open', opened_at: old }, now: now)).to be(false)
    expect(described_class.map_eligible?({ status: 'Open', opened_at: recent, closed_at: now }, now: now)).to be(false)
  end

  it 'uses red only for a missed update, without changing status' do
    row = { status: 'In Progress', opened_at: now - (20 * 86_400), updated_at: now - (15 * 86_400) }
    expect(described_class.map_signal(row, now: now)).to eq('no_recent_update')
    expect(described_class.map_eligible?(row, now: now)).to be(true)
  end
end
