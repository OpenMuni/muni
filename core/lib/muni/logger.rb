require 'logger'

module Muni
  module Logger
    LEVELS = { 'DEBUG' => ::Logger::DEBUG, 'INFO' => ::Logger::INFO,
               'WARN' => ::Logger::WARN, 'ERROR' => ::Logger::ERROR }.freeze
    CREDENTIAL = /((?:authorization|api[_-]?key|app[_-]?token|access[_-]?token|token|secret|password)
      \s*["']?\s*[:=]\s*["']?)(?:(?:Bearer|Basic)\s+)?[^\s"'&,;<>]+/ix

    def self.instance
      @instance ||= build
    end

    def self.build
      io = ENV['MUNI_LOG_FILE'] ? File.open(ENV['MUNI_LOG_FILE'], 'a') : $stdout
      logger = ::Logger.new(io)
      logger.level = LEVELS.fetch((ENV['MUNI_LOG_LEVEL'] || 'INFO').upcase, ::Logger::INFO)
      logger.formatter = proc do |sev, time, _prog, msg|
        "#{time.utc.iso8601} #{sev.ljust(5)} #{redact(msg)}\n"
      end
      logger
    end

    def self.reset!
      @instance = nil
    end

    def self.redact(message)
      text = message.to_s.gsub(%r{(https?://)[^/\s@]+@}, '\1[REDACTED]@')
      text = text.gsub(CREDENTIAL, '\1[REDACTED]')
      ENV.each_pair do |name, value|
        next unless name.match?(/(?:TOKEN|SECRET|PASSWORD|API_KEY)\z/) && value.length >= 8

        text = text.gsub(value, '[REDACTED]')
      end
      text
    end
  end
end
