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
end
