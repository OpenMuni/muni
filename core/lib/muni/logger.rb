require 'logger'

module Muni
  module Logger
    LEVELS = { 'DEBUG' => ::Logger::DEBUG, 'INFO' => ::Logger::INFO,
               'WARN' => ::Logger::WARN, 'ERROR' => ::Logger::ERROR }.freeze

    def self.instance
      @instance ||= build
    end

    def self.build
      io = ENV['MUNI_LOG_FILE'] ? File.open(ENV['MUNI_LOG_FILE'], 'a') : $stdout
      logger = ::Logger.new(io)
      logger.level = LEVELS.fetch((ENV['MUNI_LOG_LEVEL'] || 'INFO').upcase, ::Logger::INFO)
      logger.formatter = proc do |sev, time, _prog, msg|
        "#{time.utc.iso8601} #{sev.ljust(5)} #{msg}\n"
      end
      logger
    end

    def self.reset!
      @instance = nil
    end
  end
end
