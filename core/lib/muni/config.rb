module Muni
  module Config
    # Walk up from core/lib until we find a directory containing a `core/` and
    # `data/` sibling. That's the repo root regardless of where the gem is
    # mounted from.
    def self.repo_root
      @repo_root ||= ENV.fetch('MUNI_ROOT') { detect_root }
    end

    def self.detect_root
      path = File.expand_path('..', __dir__)
      until File.directory?(File.join(path, 'core')) && File.directory?(File.join(path, 'data'))
        parent = File.expand_path('..', path)
        break path if parent == path

        path = parent
      end
      path
    end

    def self.data_dir
      ENV['MUNI_DATA_DIR'] || File.join(repo_root, 'data')
    end

    def self.db_path
      ENV['MUNI_DB_PATH'] || File.join(data_dir, 'db', 'muni.sqlite3')
    end

    def self.migrations_dir
      File.join(data_dir, 'db', 'migrate')
    end

    def self.halls_dir
      File.join(repo_root, 'core', 'halls')
    end

    def self.require_env!(name)
      ENV[name] or raise "Missing required env var #{name}. See .env.example for the full list."
    end

    def self.reset!
      @repo_root = nil
    end
  end
end
