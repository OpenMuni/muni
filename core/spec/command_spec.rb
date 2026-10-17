require 'spec_helper'
require 'stringio'

RSpec.describe Muni::Command do
  let(:cmd_class) do
    Class.new(described_class) do
      argument :name, required: true
      option :format, default: 'text'
      question :confirm, prompt: 'Sure?', default: 'y', required: false

      attr_reader :went

      def go
        @went = { name: args[:name], format: opts[:format], confirm: answers[:confirm] }
        emit(@went)
      end
    end
  end

  def run(argv, stdin: StringIO.new)
    out = StringIO.new
    err = StringIO.new
    inst = cmd_class.new(argv, stdout: out, stderr: err, stdin: stdin)
    code = inst.call
    [code, out.string, err.string, inst]
  end

  it 'auto-accepts on -y and emits JSON' do
    code, out, = run(['cambridge', '-y', '--json'])
    expect(code).to eq(0)
    expect(JSON.parse(out)).to eq('name' => 'cambridge', 'format' => 'text', 'confirm' => 'y')
  end

  it 'auto-accepts when stdin is non-TTY (even without -y)' do
    fake_stdin = StringIO.new
    expect(fake_stdin.tty?).to be(false)
    code, _, _, inst = run(['cambridge', '--json'], stdin: fake_stdin)
    expect(code).to eq(0)
    expect(inst.went[:confirm]).to eq('y')
  end

  it 'errors with non-zero exit when a required arg is missing' do
    code, _, err = run(['-y'])
    expect(code).to eq(1)
    expect(err).to include('missing required argument: name')
  end

  it 'rejects unknown options' do
    code, _, err = run(['cambridge', '--nope=1', '-y'])
    expect(code).to eq(1)
    expect(err).to include('unknown option')
  end
end
