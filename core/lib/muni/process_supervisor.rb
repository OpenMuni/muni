module Muni
  # One Machine, with independent web, proxy and collector processes. A failed
  # child fails the whole unit so Fly can restart a complete, working service.
  class ProcessSupervisor
    def initialize(commands, shutdown_timeout: 20, logger: $stderr)
      raise ArgumentError, 'At least one supervised command is required' if commands.empty?

      @commands = commands
      @shutdown_timeout = shutdown_timeout
      @logger = logger
      @children = {}
      @groups = []
    end

    def run
      previous = %w[TERM INT].to_h { |signal| [signal, Signal.trap(signal) { @stop = true }] }
      start_children
      monitor
    rescue SystemCallError => e
      @logger.puts("supervisor: could not start service: #{e.message}")
      1
    ensure
      shutdown
      previous&.each { |signal, handler| Signal.trap(signal, handler) }
    end

    private

    def start_children
      @commands.each do |name, command|
        break if @stop

        pid = Process.spawn(*command, pgroup: true)
        @children[pid] = name
        @groups << pid
        @logger.puts("supervisor: started #{name} (#{pid})")
      end
    end

    def monitor
      loop do
        return 0 if @stop

        child = Process.wait2(-1, Process::WNOHANG)
        if child
          pid, status = child
          name = @children.delete(pid)
          @logger.puts("supervisor: #{name} exited unexpectedly (#{status}); stopping all services")
          return status.success? ? 1 : (status.exitstatus || (128 + status.termsig))
        end
        sleep 0.05
      end
    end

    def shutdown
      signal_groups('TERM')
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @shutdown_timeout
      until @children.empty?
        reap_children
        break if @children.empty? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.05
      end
      signal_groups('KILL')
      @children.each_key do |pid|
        Process.waitpid(pid)
      rescue Errno::ECHILD
        nil
      end
      @children.clear
    end

    def signal_groups(signal)
      @groups.each do |pid|
        Process.kill(signal, -pid)
      rescue Errno::ESRCH
        nil
      end
    end

    def reap_children
      loop do
        child = Process.waitpid(-1, Process::WNOHANG)
        break unless child

        @children.delete(child)
      end
    rescue Errno::ECHILD
      @children.clear
    end
  end
end
