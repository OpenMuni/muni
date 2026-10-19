# A cache eviction scenario exercises the entire public response budget in one example.
# rubocop:disable RSpec/ExampleLength
require 'spec_helper'
require 'muni/public_response_cache'
require 'timeout'

RSpec.describe Muni::PublicResponseCache do
  it 'expires by age, isolates keys and enforces byte and entry limits' do
    clock = 0
    cache = described_class.new(ttl: 30, max_bytes: 1032, max_entries: 2, clock: -> { clock })
    expect(cache.fetch('a') { 'aaa' }).to eq('aaa')
    expect(cache.fetch('b') { 'bbb' }).to eq('bbb')
    expect(cache.fetch('a') { raise 'cached' }).to eq('aaa')
    cache.fetch('c') { 'ccc' }
    expect(cache.fetch('b') { 'new' }).to eq('new')
    clock = 31
    expect(cache.fetch('b') { 'old' }).to eq('old')
    expect(cache.fetch('large') { 'x' * 2000 }).to eq('x' * 2000)
    expect(cache.fetch('large') { 'again' }).to eq('again')
  end

  it 'shares work between simultaneous requests and recovers from errors' do
    cache = described_class.new
    entered = Queue.new
    release = Queue.new
    first = Thread.new do
      cache.fetch('same') do
        entered << true
        release.pop
        'result'
      end
    end
    entered.pop
    second = Thread.new { cache.fetch('same') { raise 'duplicate work' } }
    release << true
    expect([first.value, second.value]).to eq(%w[result result])
    expect { cache.fetch('error') { raise 'failure' } }.to raise_error('failure')
    expect(cache.fetch('error') { 'recovered' }).to eq('recovered')
  end

  it 'shares an oversized in-progress result even when it cannot be retained in the cache' do
    cache = described_class.new(max_bytes: 1)
    entered = Queue.new
    release = Queue.new
    first = Thread.new do
      cache.fetch('same') do
        entered << true
        release.pop
        'oversized'
      end
    end
    entered.pop
    second = Thread.new { cache.fetch('same') { raise 'duplicate computation' } }
    Timeout.timeout(1) { Thread.pass until second.status == 'sleep' }
    release << true
    expect([first.value, second.value]).to eq(%w[oversized oversized])
    expect(cache.fetch('same') { 'fresh' }).to eq('fresh')
  end

  it 'enforces byte and entry ceilings independently' do
    [{ max_bytes: 516, max_entries: 128 }, { max_bytes: 100_000, max_entries: 1 }].each do |bounds|
      cache = described_class.new(**bounds)
      cache.fetch('a') { 'aaa' }
      cache.fetch('b') { 'bbb' }
      expect(cache.fetch('a') { 'new' }).to eq('new')
    end
  end

  it 'releases all waiters after a failed computation and permits the next attempt' do
    cache = described_class.new
    entered = Queue.new
    release = Queue.new
    first = Thread.new do
      cache.fetch('failure') do
        entered << true
        release.pop
        raise 'failed'
      end
    rescue StandardError => e
      e.message
    end
    entered.pop
    second = Thread.new do
      cache.fetch('failure') { 'unexpected recomputation' }
    rescue StandardError => e
      e.message
    end
    Timeout.timeout(1) { Thread.pass until second.status == 'sleep' }
    release << true
    expect([first.value, second.value]).to eq(%w[failed failed])
    expect(cache.fetch('failure') { 'recovered' }).to eq('recovered')
  end
end
# rubocop:enable RSpec/ExampleLength
