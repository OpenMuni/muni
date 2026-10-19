require 'English'
module Muni
  # rubocop:disable Metrics/AbcSize
  # Bounded cache of serialized public responses. Never caches exceptions.
  class PublicResponseCache
    def initialize(ttl: 30, max_bytes: 32 * 1024 * 1024, max_entries: 128, clock: lambda {
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    })
      @ttl = ttl
      @max_bytes = max_bytes
      @max_entries = max_entries
      @clock = clock
      @mutex = Mutex.new
      @entries = {}
      @pending = {}
      @bytes = 0
    end

    def fetch(key)
      leader = false
      pending = nil
      @mutex.synchronize do
        expire!
        if (entry = @entries.delete(key))
          @entries[key] = entry
          return entry[:value]
        end
        if (pending = @pending[key])
          pending[:condition].wait(@mutex) until pending[:done]
          raise pending[:error] if pending[:error]

          return pending[:value]
        end
        pending = @pending[key] = { condition: ConditionVariable.new, done: false }
        leader = true
      end
      started = @clock.call
      value = yield
      @mutex.synchronize do
        # Reserve key storage and per-entry Ruby bookkeeping as well as payload bytes.
        size = value.bytesize + key.bytesize + 512
        if size <= @max_bytes && @clock.call - started < @ttl
          remove!(@entries.keys.first) while @entries.size >= @max_entries || @bytes + size > @max_bytes
          @entries[key] = { value: value.freeze, bytes: size, expires: started + @ttl }
          @bytes += size
        end
      end
      value
    ensure
      if leader
        error = $ERROR_INFO
        @mutex.synchronize do
          pending[:value] = value
          pending[:error] = error
          pending[:done] = true
          @pending.delete(key)
          pending[:condition].broadcast
        end
      end
    end

    def clear
      @mutex.synchronize do
        @entries.clear
        @bytes = 0
      end
    end

    private

    def expire!
      @entries.each_key { |key| remove!(key) if @entries[key][:expires] <= @clock.call }
    end

    def remove!(key)
      @bytes -= @entries.delete(key)[:bytes]
    end
  end
end
# rubocop:enable Metrics/AbcSize
