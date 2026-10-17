require 'spec_helper'

RSpec.describe Muni::Get::Registry do
  it 'finds only canonical launch domains' do
    expect(described_class.find(:police).slug).to eq(:police)
    expect(described_class.find('crashes').slug).to eq(:crashes)
    expect(described_class.find('service-requests')).to be_nil
    expect(described_class.find('vision-zero')).to be_nil
  end

  it 'maps Cambridge providers' do
    domain = described_class.find!(:food_trucks)
    prov = domain.provider(:cambridge)
    expect(prov.source_slug).to eq('cambridge/food_trucks')
    expect(prov.record_slug).to eq('food_trucks')
  end

  it 'keeps meetings as a provider without exposing it as a public category' do
    domain = described_class.find!(:meetings)
    expect(domain.provider(:cambridge).source_slug).to eq('cambridge/meetings')
    expect(described_class.view_categories.map { |row| row[:slug] }).not_to include(:meetings)
  end

  it 'requires zone for city-scoped domains' do
    domain = described_class.find!(:police)
    expect(domain.requires_zone).to be(true)
    expect(domain.provider_keys).to eq([:cambridge])
  end

  it 'keeps category source slugs registered as sources and beats' do
    Muni.boot!
    slugs = described_class.category_source_slugs
    slugs.each do |slug|
      expect(Muni::Registry.source(slug)).to be_a(Class), "missing source #{slug}"
      expect(Muni::Registry.beat(slug)).to be < Muni::Beat, "missing beat #{slug}"
    end
  end

  it 'covers every category source in domain providers' do
    domain_slugs = described_class.domain_source_slugs
    described_class.category_source_slugs.each do |slug|
      expect(domain_slugs).to include(slug), "#{slug} missing from DOMAINS providers"
    end
  end
end
