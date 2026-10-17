require 'spec_helper'
require 'muni/process_supervisor'
require 'rbconfig'
require 'timeout'

RSpec.describe Muni::ProcessSupervisor do
  let(:directory) { Dir.mktmpdir('muni-supervisor') }
  let(:process_state) { {} }

  around do |example|
    example.run
  ensure
    cleanup_supervisor
    FileUtils.rm_rf(directory)
  end

  def child_command(name, exit_code: nil, ignore_term: false)
    script = <<~RUBY
      stop = #{File.join(directory, "#{name}.stopped").inspect}
      Signal.trap('TERM') { #{ignore_term ? 'nil' : 'File.write(stop, "TERM"); exit 0'} }
      File.write(#{File.join(directory, "#{name}.ready").inspect}, Process.pid)
      loop do
        exit #{exit_code || 0} if #{!exit_code.nil?} && File.exist?(#{File.join(directory, 'exit').inspect})
        sleep 0.01
      end
    RUBY
    [RbConfig.ruby, '-e', script]
  end

  def start_supervisor(commands, wait_for: commands.keys)
    script = 'exit Muni::ProcessSupervisor.new(JSON.parse(ARGV.fetch(0)), shutdown_timeout: 0.2).run'
    path = File.expand_path('../lib/muni/process_supervisor', __dir__)
    process_state[:pid] = Process.spawn(RbConfig.ruby, '-rjson', '-r', path, '-e', script, JSON.generate(commands),
                                        out: File.join(directory, 'log'), err: %i[child out])
    wait_until { wait_for.all? { |name| File.exist?(File.join(directory, "#{name}.ready")) } }
  end

  def wait_until(&block)
    Timeout.timeout(5) { sleep 0.01 until block.call }
  end

  def finish_supervisor
    _, status = Timeout.timeout(5) { Process.wait2(process_state[:pid]) }
    process_state[:pid] = nil
    status.exitstatus
  end

  def cleanup_supervisor
    return unless process_state[:pid]

    Process.kill('TERM', process_state[:pid])
    Timeout.timeout(5) { Process.wait(process_state[:pid]) }
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  %w[web proxy beats].each do |failed|
    it "stops every sibling and fails when #{failed} exits nonzero" do
      commands = %w[web proxy beats].to_h { |name| [name, child_command(name, exit_code: name == failed ? 7 : nil)] }
      start_supervisor(commands)
      File.write(File.join(directory, 'exit'), '')

      expect(finish_supervisor).to eq(7)
      expect((commands.keys - [failed]).all? do |name|
        File.exist?(File.join(directory, "#{name}.stopped"))
      end).to be(true)
    end
  end

  it 'treats an unexpected successful child exit as a failure of the service' do
    start_supervisor({ 'web' => child_command('web', exit_code: 0), 'proxy' => child_command('proxy') })
    File.write(File.join(directory, 'exit'), '')
    expect(finish_supervisor).to eq(1)
    expect(File).to exist(File.join(directory, 'proxy.stopped'))
  end

  %w[TERM INT].each do |signal|
    it "gracefully stops all children on #{signal}" do
      start_supervisor(%w[web proxy beats].to_h { |name| [name, child_command(name)] })
      Process.kill(signal, process_state[:pid])
      expect(finish_supervisor).to eq(0)
      expect(%w[web proxy beats].all? { |name| File.exist?(File.join(directory, "#{name}.stopped")) }).to be(true)
    end
  end

  it 'kills and reaps a child that does not stop before the deadline' do
    start_supervisor({ 'web' => child_command('web', ignore_term: true), 'proxy' => child_command('proxy') })
    child_pid = File.read(File.join(directory, 'web.ready')).to_i
    Process.kill('TERM', process_state[:pid])
    expect(finish_supervisor).to eq(0)
    expect { Process.kill(0, child_pid) }.to raise_error(Errno::ESRCH)
  end

  it 'stops the already-started child when another executable cannot be started' do
    start_supervisor({ 'web' => child_command('web'), 'proxy' => ['/missing/muni-caddy'] }, wait_for: [])
    expect(finish_supervisor).to eq(1)
    log = File.read(File.join(directory, 'log'))
    child_pid = log.match(/started web \((\d+)\)/)[1].to_i
    expect(log).to include('could not start service')
    expect { Process.kill(0, child_pid) }.to raise_error(Errno::ESRCH)
  end

  it 'forwards shutdown to descendants in a child process group' do
    grandchild = child_command('descendant')
    prelude = "Process.spawn(*#{grandchild.inspect}); sleep 0.01 until " \
              "File.exist?(#{File.join(directory, 'descendant.ready').inspect}); "
    command = child_command('web')
    command[-1] = prelude + command.last
    start_supervisor({ 'web' => command, 'proxy' => child_command('proxy') })
    Process.kill('TERM', process_state[:pid])

    expect(finish_supervisor).to eq(0)
    expect(File).to exist(File.join(directory, 'descendant.stopped'))
  end

  it 'starts only web and proxy when the production entrypoint has the scheduler disabled' do
    FileUtils.mkdir_p(File.join(directory, 'cli/exe'))
    File.write(File.join(directory, 'cli/exe/muni'), child_command('web').last)
    proxy = File.join(directory, 'caddy')
    File.write(proxy, "#!#{RbConfig.ruby}\n#{child_command('proxy').last}")
    File.chmod(0o755, proxy)
    entrypoint = File.expand_path('../../bin/supervise-web', __dir__)
    process_state[:pid] = Process.spawn({ 'MUNI_WEB_BEATS' => '0', 'CADDY_BIN' => proxy }, RbConfig.ruby, entrypoint,
                                        chdir: directory, out: File.join(directory, 'log'), err: %i[child out])
    wait_until { %w[web proxy].all? { |name| File.exist?(File.join(directory, "#{name}.ready")) } }
    Process.kill('TERM', process_state[:pid])
    expect(finish_supervisor).to eq(0)
    expect(File.read(File.join(directory, 'log'))).not_to include('started beats')
  end
end
