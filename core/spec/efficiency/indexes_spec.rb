require 'spec_helper'

RSpec.describe Muni::EfficiencyIndexes do
  before { Muni::Store.ensure_tables! }

  it 'drops only exact nonunique duplicates, records recreation SQL, and is idempotent' do
    db = Muni::Store.db
    db.run('CREATE INDEX duplicate_dates ON service_requests (hall, opened_at)')
    db.run('CREATE INDEX different_direction ON service_requests (hall, opened_at DESC)')
    db.run('CREATE INDEX partial_dates ON service_requests (hall, opened_at) WHERE closed_at IS NULL')
    db.run('CREATE UNIQUE INDEX unique_dates ON service_requests (hall, opened_at)')
    described_class.prepare!
    names = described_class.definitions(db, :service_requests).map { |index| index[:name] }
    expect(names).to include('different_direction', 'partial_dates', 'unique_dates')
    expect(names).to include('service_requests_efficiency_order')
    expect(db.indexes(:service_requests)).to have_key(:service_requests_efficiency_order)
    expect(db[:efficiency_index_changes].count).to eq(1)
    expect(db[:efficiency_index_changes].first[:recreate_sql]).to include('CREATE INDEX')
    described_class.prepare!
    expect(db[:efficiency_index_changes].count).to eq(1)
  end

  it 'preserves collation, direction, predicates, unique and primary-key distinctions' do
    db = Muni::Store.db
    db.run('CREATE INDEX status_binary ON service_requests (status COLLATE BINARY)')
    db.run('CREATE INDEX status_nocase ON service_requests (status COLLATE NOCASE)')
    db.run('CREATE INDEX status_desc ON service_requests (status DESC)')
    db.run('CREATE INDEX status_open ON service_requests (status) WHERE status = \'Open\'')
    db.run('CREATE INDEX status_closed ON service_requests (status) WHERE status = \'Closed\'')
    db.run('CREATE INDEX status_expression ON service_requests (lower(status))')
    db.run('CREATE INDEX status_expression_copy ON service_requests (lower(status))')
    described_class.prepare!
    names = described_class.definitions(db, :service_requests).map { |index| index[:name] }
    expect(names).to include('status_binary', 'status_nocase', 'status_desc', 'status_open', 'status_closed')
    expect(names.grep(/status_expression/).length).to eq(1)
    expect(db.fetch('PRAGMA index_list(service_requests)').any? { |row| row[:origin] == 'pk' }).to be(true)
  end
end
