require 'json'

module Muni
  # Lifecycle: setup -> parse_arguments -> ask -> validate_required -> go
  #
  # Each command declares its CLI surface with `argument` / `option` / `question`.
  # `-y` (or non-TTY STDIN) auto-accepts every question, returning its default.
  # `--json` is a universal option commands inspect via `json?`.
  #
  #   class Halls::Show < Muni::Command
  #     argument :slug
  #     option :format, default: 'text'
  #
  #     def go
  #       hall = Muni::Hall.find(args[:slug]) or fail!("no hall #{args[:slug]}")
  #       emit(hall.to_h)
  #     end
  #   end
  class Command
    class Abort < StandardError
    end

    class MissingArgument < Abort
    end

    class MissingAnswer < Abort
    end

    class UnknownOption < Abort
    end

    DEFAULT_OPTIONS = {
      yes:  { short: 'y', boolean: true, default: false },
      json: { boolean: true, default: false },
      help: { boolean: true, default: false }
    }.freeze

    class << self
      def arguments = @arguments ||= []
      def options = @options ||= DEFAULT_OPTIONS.dup
      def questions = @questions ||= []

      def argument(name, type: :string, default: nil, required: false)
        arguments << { name: name, type: type, default: default, required: required }
      end

      def option(name, short: nil, type: :string, default: nil, boolean: false)
        options[name] = { short: short, type: type, default: default, boolean: boolean }
      end

      def question(key, prompt:, default: nil, required: false, when: nil)
        questions << { key: key, prompt: prompt, default: default, required: required,
when: binding.local_variable_get(:when) }
      end

      def description(text = nil)
        @description = text if text
        @description
      end
    end

    attr_reader :argv, :args, :opts, :answers, :stdout, :stderr, :stdin

    def initialize(argv = [], stdout: $stdout, stderr: $stderr, stdin: $stdin)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @stdin = stdin
      @args = {}
      @opts = {}
      @answers = {}
    end

    def call
      setup
      parse_arguments
      return print_help_and_exit if opts[:help]

      ask
      validate_required
      go
      0
    rescue Abort => e
      stderr.puts e.message
      1
    end

    # Override hooks. Subclasses fill these in.
    def setup; end
    def go = raise(NotImplementedError, "#{self.class} must implement #go")

    def json?
      !!opts[:json]
    end

    def yes?
      !!opts[:yes] || !stdin.tty?
    end

    def emit(payload)
      if json?
        stdout.puts JSON.generate(payload)
      elsif payload.is_a?(Array)
        payload.each { |row| print_row(row) }
      else
        print_row(payload)
      end
    end

    def fail!(msg)
      raise Abort, msg
    end

    # ---------- lifecycle internals ----------

    def parse_arguments
      tokens = argv.dup
      positionals = []

      while (tok = tokens.shift)
        if tok.start_with?('--')
          name, val = tok[2..].split('=', 2)
          consume_option(name.to_sym, val, tokens)
        elsif tok.start_with?('-') && tok.length > 1
          short = tok[1..]
          name = find_option_by_short(short)
          consume_option(name, nil, tokens)
        else
          positionals << tok
        end
      end

      assign_positionals(positionals)
      apply_option_defaults
    end

    def ask
      self.class.questions.each do |q|
        next if q[:when] && !instance_exec(&q[:when])

        @answers[q[:key]] = if yes?
                              q[:default]
                            else
                              prompt_user(q)
                            end
      end
    end

    def validate_required
      self.class.arguments.each do |a|
        next unless a[:required]
        next unless @args[a[:name]].nil?

        raise MissingArgument, "missing required argument: #{a[:name]}"
      end

      self.class.questions.each do |q|
        next unless q[:required]
        next unless @answers[q[:key]].nil?

        raise MissingAnswer, "missing required answer for: #{q[:key]} (use --#{q[:key]}=... or run interactively)"
      end
    end

    # ---------- helpers ----------

    private

    def print_help_and_exit
      stdout.puts(help_text)
      throw :command_done, 0
    rescue UncaughtThrowError
      0
    end

    def help_text
      lines = [(self.class.description || self.class.name).to_s]
      lines << ''
      lines << 'Arguments:' unless self.class.arguments.empty?
      self.class.arguments.each do |a|
        flag = "  <#{a[:name]}>#{'*' if a[:required]}"
        lines << flag
      end
      lines << ''
      lines << 'Options:'
      self.class.options.each do |name, cfg|
        prefix = cfg[:boolean] ? "  --#{name}" : "  --#{name}=VALUE"
        prefix += " (-#{cfg[:short]})" if cfg[:short]
        lines << "#{prefix}  default=#{cfg[:default].inspect}"
      end
      lines.join("\n")
    end

    def consume_option(name, value, rest)
      cfg = self.class.options[name] or raise UnknownOption, "unknown option: --#{name}"
      opts[name] = if cfg[:boolean]
                     true
                   else
                     value || rest.shift
                   end
    end

    def find_option_by_short(short)
      self.class.options.each { |name, cfg| return name if cfg[:short] == short }
      raise UnknownOption, "unknown short option: -#{short}"
    end

    def assign_positionals(tokens)
      self.class.arguments.each_with_index do |a, i|
        val = tokens[i]
        @args[a[:name]] = coerce(val.nil? ? a[:default] : val, a[:type])
      end
    end

    def apply_option_defaults
      self.class.options.each do |name, cfg|
        opts[name] = cfg[:default] unless opts.key?(name)
      end
    end

    def coerce(value, type)
      return value if value.nil?

      case type
      when :integer then value.to_i
      when :float   then value.to_f
      when :boolean then [true, 'true', '1', 'yes', 'y'].include?(value)
      else value.to_s
      end
    end

    def prompt_user(question)
      label = question[:prompt]
      label += " [#{question[:default]}]" if question[:default]
      stdout.print("#{label}: ")
      stdout.flush
      raw = stdin.gets&.strip
      raw.nil? || raw.empty? ? question[:default] : raw
    end

    def print_row(row)
      case row
      when Hash
        row.each { |k, v| stdout.puts(format('%<key>-18s %<val>s', key: k, val: v)) }
        stdout.puts('')
      else
        stdout.puts(row.to_s)
      end
    end
  end
end
