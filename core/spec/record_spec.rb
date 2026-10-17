require 'spec_helper'

RSpec.describe Muni::Record do
  describe 'schema DSL' do
    let(:klass) do
      Class.new(described_class) do
        schema do
          string  :external_id, primary: true
          string  :hall, indexed: true
          time    :opened_at
          point   :location
          integer :count
        end

        def self.name = 'Demo'
      end
    end

    it 'captures column metadata' do
      cols = klass.schema_def.columns
      expect(cols.map(&:name)).to eq(%i[external_id hall opened_at location count])
      expect(klass.schema_def.primary_key).to eq(:external_id)
    end

    it 'exposes attribute accessors for declared columns' do
      r = klass.new(external_id: 'a', hall: 'cambridge', count: 3)
      expect(r.hall).to eq('cambridge')
      expect(r.to_h).to include(external_id: 'a', hall: 'cambridge', count: 3)
    end

    it 'silently keeps undeclared kwargs as metadata' do
      r = klass.new(external_id: 'a', source: 'cambridge/foo')
      expect(r.metadata).to include(source: 'cambridge/foo')
      expect(r.to_h).not_to include(:source)
    end
  end
end
